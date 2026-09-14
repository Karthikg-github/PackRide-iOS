/**
 * PackRide push notifications.
 *
 * Two Cloud Functions, both triggered by changes that already happen in the
 * app today — no new "ride started" event needed:
 *
 *   1. notifyFollowersOnSoloRideStart
 *      Watches /users/{uid}/location/isOnline. The app flips this to true
 *      the moment a solo ride starts (ActiveSoloRideView.swift) and false
 *      when it ends. On the false/undefined -> true transition, we notify
 *      everyone who follows that rider.
 *
 *   2. notifyCommunityOnRideStart
 *      Watches /communities/{communityId}/members/{uid}/isRiding. Same idea,
 *      but for community members riding — notifies the rest of that
 *      community.
 *
 * Both functions run with the Admin SDK, which bypasses the Realtime
 * Database security rules entirely, so no rule changes were needed for this
 * feature.
 */

const functions = require("firebase-functions");
const admin = require("firebase-admin");
const { RtcTokenBuilder, RtcRole } = require("agora-token");
const nodemailer = require("nodemailer");

admin.initializeApp();
const db = admin.database();
const messaging = admin.messaging();

/**
 * Sends a notification to a list of user/member IDs, each of which has an
 * `fcmToken` field somewhere under the given ref template. Cleans up tokens
 * that FCM reports as no-longer-valid (app uninstalled, etc.) so the list
 * doesn't grow stale.
 *
 * @param {Array<{id: string, token: string}>} recipients
 * @param {string} title
 * @param {string} body
 * @param {(id: string) => admin.database.Reference} tokenRefFor - given an
 *   id, returns the DB ref where that recipient's fcmToken lives (used only
 *   for cleanup on invalid tokens).
 */
async function sendPush(recipients, title, body, tokenRefFor, options = {}) {
  const withTokens = recipients.filter((r) => !!r.token);
  if (!withTokens.length) return;

  const message = {
    notification: { title, body },
    data: options.data || {},
    tokens: withTokens.map((r) => r.token),
  };
  if (options.safety === true) {
    message.android = {
      priority: "high",
      notification: { channelId: "packride_safety", sound: "default", visibility: "private" },
    };
    message.apns = {
      headers: { "apns-priority": "10" },
      payload: { aps: { sound: "default", "interruption-level": "time-sensitive" } },
    };
  }

  try {
    const response = await messaging.sendEachForMulticast(message);
    response.responses.forEach((res, idx) => {
      if (!res.success) {
        const code = res.error && res.error.code;
        if (code === "messaging/registration-token-not-registered") {
          const recipient = withTokens[idx];
          (recipient.tokenRef || tokenRefFor(recipient.id)).remove().catch(() => {});
        }
      }
    });
  } catch (err) {
    console.error("PackRide: FCM send failed —", err);
  }
}

// Read every installation registered to an account. The legacy scalar is
// retained as a migration fallback and de-duplicated against the token map.
async function userPushRecipients(uid) {
  const snap = await db.ref(`users/${uid}`).once("value");
  const value = snap.val() || {};
  const tokens = new Map();
  Object.entries(value.fcmTokens || {}).forEach(([deviceID, token]) => {
    if (token) tokens.set(token, {
      id: uid,
      token,
      tokenRef: db.ref(`users/${uid}/fcmTokens/${deviceID}`),
    });
  });
  if (value.fcmToken && !tokens.has(value.fcmToken)) {
    tokens.set(value.fcmToken, {
      id: uid,
      token: value.fcmToken,
      tokenRef: db.ref(`users/${uid}/fcmToken`),
    });
  }
  return [...tokens.values()];
}

// A Realtime Database follow request is also the recipient's durable in-app
// notification. This trigger adds the missing cross-platform push delivery;
// every registered iOS/Android installation for the account is notified.
exports.notifyOnFollowRequest = functions.database
  .ref("/users/{recipientUID}/followRequests/{senderUID}")
  .onCreate(async (snapshot, context) => {
    const request = snapshot.val() || {};
    const recipientUID = context.params.recipientUID;
    const senderUID = context.params.senderUID;
    if (!recipientUID || !senderUID || recipientUID === senderUID) return null;
    const recipients = await userPushRecipients(recipientUID);
    await sendPush(
      recipients,
      "New follow request",
      `${request.name || "A PackRide rider"} wants to follow you`,
      () => db.ref(`users/${recipientUID}/fcmToken`),
      {data: {type: "follow_request", senderUID}}
    );
    return null;
  });

// Private live-location fan-out. A rider can share with all followers or an
// explicit allow-list; syncing on visibility changes revokes a removed person
// immediately instead of waiting for another GPS update.
async function excludeBlockedLocationRecipients(senderUID, candidateUIDs) {
  const unique = [...new Set(candidateUIDs)].filter((uid) => uid && uid !== senderUID);
  if (!unique.length) return [];
  const senderBlocked = (await db.ref(`users/${senderUID}/blockedUsers`).once("value")).val() || {};
  const candidates = unique.filter((uid) => !senderBlocked[uid]);
  const viewerBlockSnaps = await Promise.all(
    candidates.map((uid) => db.ref(`users/${uid}/blockedUsers/${senderUID}`).once("value"))
  );
  return candidates.filter((uid, index) => !viewerBlockSnaps[index].exists());
}

async function syncFollowerLocationAudience(uid, location) {
  const [visibilitySnap, followersSnap, deliveredSnap] = await Promise.all([
    db.ref(`users/${uid}/locationVisibility`).once("value"),
    db.ref(`users/${uid}/followers`).once("value"),
    db.ref(`locationDeliveryIndex/${uid}/followers`).once("value"),
  ]);
  const visibility = visibilitySnap.val() || {};
  const previouslyDelivered = deliveredSnap.val() || {};
  const writes = {};

  if (!location || location.isOnline !== true || visibility.followers !== true) {
    Object.keys(previouslyDelivered).forEach((viewerUID) => {
      writes[`locationFeeds/${viewerUID}/${uid}`] = null;
    });
    writes[`locationDeliveryIndex/${uid}/followers`] = null;
    return Object.keys(writes).length ? db.ref().update(writes) : null;
  }

  const followers = await excludeBlockedLocationRecipients(uid, Object.keys(followersSnap.val() || {}));
  const selected = visibility.selectedFollowers || {};
  const recipients = visibility.followerSelectionEnabled === true
    ? followers.filter((uid) => selected[uid] === true)
    : followers;
  const recipientSet = new Set(recipients);

  Object.keys(previouslyDelivered).forEach((viewerUID) => {
    if (!recipientSet.has(viewerUID)) {
      writes[`locationFeeds/${viewerUID}/${uid}`] = null;
      writes[`locationDeliveryIndex/${uid}/followers/${viewerUID}`] = null;
    }
  });
  recipients.forEach((viewerUID) => {
    writes[`locationFeeds/${viewerUID}/${uid}`] = {
      riderUID: uid, latitude: location.latitude || 0, longitude: location.longitude || 0,
      isOnline: true, lastSeen: location.lastSeen || Date.now() / 1000, source: "follower",
    };
    writes[`locationDeliveryIndex/${uid}/followers/${viewerUID}`] = true;
  });
  return Object.keys(writes).length ? db.ref().update(writes) : null;
}

exports.fanoutFollowerLocation = functions.database
  .ref("/users/{uid}/location")
  .onWrite((change, context) => syncFollowerLocationAudience(context.params.uid, change.after.val()));

exports.syncFollowerLocationAudience = functions.database
  .ref("/users/{uid}/locationVisibility")
  .onWrite(async (change, context) => {
    const location = (await db.ref(`users/${context.params.uid}/location`).once("value")).val();
    return syncFollowerLocationAudience(context.params.uid, location);
  });

async function syncCommunityLocationAudience(uid, location) {
    if (!location || location.isOnline !== true) {
      const recipients = (await db.ref(`locationDeliveryIndex/${uid}/communities`).once("value")).val() || {};
      const writes = {};
      Object.keys(recipients).forEach((viewerUID) => { writes[`locationFeeds/${viewerUID}/${uid}`] = null; });
      writes[`locationDeliveryIndex/${uid}/communities`] = null;
      return db.ref().update(writes);
    }
    const [enabledSnap, deliveredSnap] = await Promise.all([
      db.ref(`users/${uid}/locationVisibility/communities`).once("value"),
      db.ref(`locationDeliveryIndex/${uid}/communities`).once("value"),
    ]);
    const previouslyDelivered = deliveredSnap.val() || {};
    if (enabledSnap.val() !== true) {
      const removals = {};
      Object.keys(previouslyDelivered).forEach((viewerUID) => {
        removals[`locationFeeds/${viewerUID}/${uid}`] = null;
      });
      removals[`locationDeliveryIndex/${uid}/communities`] = null;
      return db.ref().update(removals);
    }
    const memberships = (await db.ref(`users/${uid}/communityMemberships`).once("value")).val() || {};
    const candidates = new Set();
    await Promise.all(Object.keys(memberships).map(async (communityID) => {
      const members = (await db.ref(`communities/${communityID}/members`).once("value")).val() || {};
      Object.values(members).forEach((member) => {
        if (member && member.authUID && member.authUID !== uid) {
          candidates.add(member.authUID);
        }
      });
    }));
    const recipients = await excludeBlockedLocationRecipients(uid, [...candidates]);
    const recipientSet = new Set(recipients);
    const writes = {};
    Object.keys(previouslyDelivered).forEach((viewerUID) => {
      if (!recipientSet.has(viewerUID)) {
        writes[`locationFeeds/${viewerUID}/${uid}`] = null;
        writes[`locationDeliveryIndex/${uid}/communities/${viewerUID}`] = null;
      }
    });
    recipients.forEach((viewerUID) => {
      writes[`locationFeeds/${viewerUID}/${uid}`] = { riderUID: uid, latitude: location.latitude || 0, longitude: location.longitude || 0, isOnline: true, lastSeen: location.lastSeen || Date.now() / 1000, source: "community" };
      writes[`locationDeliveryIndex/${uid}/communities/${viewerUID}`] = true;
    });
    return Object.keys(writes).length ? db.ref().update(writes) : null;
}

exports.fanoutCommunityLocation = functions.database
  .ref("/users/{uid}/location")
  .onWrite((change, context) => syncCommunityLocationAudience(context.params.uid, change.after.val()));

// Changing the community privacy toggle must revoke existing feeds
// immediately; waiting for the rider's next GPS update leaves stale private
// coordinates visible for an unbounded amount of time.
exports.syncCommunityLocationAudience = functions.database
  .ref("/users/{uid}/locationVisibility/communities")
  .onWrite(async (change, context) => {
    const location = (await db.ref(`users/${context.params.uid}/location`).once("value")).val();
    return syncCommunityLocationAudience(context.params.uid, location);
  });

// A block/unblock changes both riders' effective audiences. Re-evaluate both
// sides immediately so an existing community feed is removed without waiting
// for movement, and so later GPS updates cannot recreate blocked visibility.
exports.syncLocationAudiencesOnBlock = functions.database
  .ref("/users/{uid}/blockedUsers/{otherUID}")
  .onWrite(async (change, context) => {
    const subjects = [...new Set([context.params.uid, context.params.otherUID])];
    await Promise.all(subjects.map(async (uid) => {
      const location = (await db.ref(`users/${uid}/location`).once("value")).val();
      await Promise.all([
        syncFollowerLocationAudience(uid, location),
        syncCommunityLocationAudience(uid, location),
      ]);
    }));
    return null;
  });

// Active group rides are the explicit, temporary exception to a rider's
// follower/community settings. Only current room members receive the feed.
exports.fanoutGroupRideLocation = functions.database
  .ref("/rides/{rideCode}/riders/{deviceID}")
  .onWrite(async (change, context) => {
    const rider = change.after.val() || change.before.val();
    if (!rider || !rider.authUID) return null;
    const indexPath = `groupLocationDeliveryIndex/${context.params.rideCode}/${rider.authUID}`;
    if (!change.after.exists()) {
      const recipients = (await db.ref(indexPath).once("value")).val() || {};
      const removals = {};
      Object.keys(recipients).forEach((viewerUID) => { removals[`groupLocationFeeds/${context.params.rideCode}/${viewerUID}/${rider.authUID}`] = null; });
      removals[indexPath] = null;
      return db.ref().update(removals);
    }
    const riders = (await db.ref(`rides/${context.params.rideCode}/riders`).once("value")).val() || {};
    const writes = {};
    Object.values(riders).forEach((member) => {
      if (member && member.authUID && member.authUID !== rider.authUID) {
        writes[`groupLocationFeeds/${context.params.rideCode}/${member.authUID}/${rider.authUID}`] = {
          riderUID: rider.authUID, latitude: rider.latitude || 0, longitude: rider.longitude || 0,
          speed: rider.speed || 0, timestamp: rider.timestamp || Date.now() / 1000,
          name: rider.name || "Rider", initials: rider.initials || "R",
          isLeader: rider.isLeader === true, avatarURL: rider.avatarURL || ""
        };
        writes[`${indexPath}/${member.authUID}`] = true;
      }
    });
    return Object.keys(writes).length ? db.ref().update(writes) : null;
  });

// MARK: - Crash safety incidents
// These messages use the normal notification sound and request the iOS
// time-sensitive interruption level. They deliberately do not use critical
// alerts: that capability requires Apple's separate Critical Alerts entitlement.
async function crashRecipients(incident) {
  const byToken = new Map();
  const primaryIDs = Object.keys(incident.primaryResponderUIDs || {});

  // A linked emergency contact is always eligible, whether or not they are
  // currently in the group ride. Group membership upgrades the wording below.
  const contactTokens = (await Promise.all(primaryIDs.map(async (uid) =>
    (await userPushRecipients(uid)).map((recipient) => ({ ...recipient, primary: true }))
  ))).flat();
  for (const recipient of contactTokens) {
    if (recipient.token) byToken.set(recipient.token, recipient);
  }

  if (incident.groupRideCode) {
    const riders = (await db.ref(`rides/${incident.groupRideCode}/riders`).once("value")).val() || {};
    Object.entries(riders).forEach(([deviceID, rider]) => {
      if (deviceID === incident.senderDeviceID || !rider || !rider.fcmToken) return;
      const isPrimary = !!(rider.authUID && incident.primaryResponderUIDs && incident.primaryResponderUIDs[rider.authUID]);
      const existing = byToken.get(rider.fcmToken);
      // Preserve the primary role if a contact also happens to be in the ride.
      byToken.set(rider.fcmToken, existing ? { ...existing, primary: existing.primary || isPrimary } : {
        id: deviceID,
        token: rider.fcmToken,
        primary: isPrimary,
        tokenRef: db.ref(`rides/${incident.groupRideCode}/riders/${deviceID}/fcmToken`),
      });
    });
  }
  return [...byToken.values()];
}

async function sendCrashPush(incidentID, incident, reminder = false) {
  const recipients = await crashRecipients(incident);
  await Promise.all(recipients.map(async (recipient) => {
    const title = reminder ? `🚨 Reminder: ${incident.senderName || "A rider"} needs a response` :
      `🚨 ${incident.senderName || "A rider"} may have crashed`;
    const body = recipient.primary
      ? "You are listed as an emergency contact. Tap to confirm you’re checking on them."
      : "A rider in your group may need help. Tap to view the incident location.";
    try {
      await messaging.send({
        token: recipient.token,
        notification: { title, body },
        data: { packrideType: "crashIncident", incidentID, mapURL: incident.mapURL || "" },
        android: {
          priority: "high",
          notification: { channelId: "packride_safety", sound: "default", visibility: "private" },
        },
        apns: { headers: { "apns-priority": "10" }, payload: { aps: {
          sound: "default", "interruption-level": "time-sensitive"
        }}},
      });
    } catch (err) {
      console.error("PackRide: crash push failed", err);
      if (err && err.code === "messaging/registration-token-not-registered") {
        recipient.tokenRef.remove().catch(() => {});
      }
    }
  }));
}

// The inbox is written by Admin SDK rather than the crashing rider's client.
// That lets database rules keep /users/{uid} private to its owner.
async function writeCrashInboxes(incidentID, incident) {
  const primaryIDs = Object.keys(incident.primaryResponderUIDs || {});
  if (!primaryIDs.length) return;
  const payload = {
    senderName: incident.senderName || "A PackRide rider",
    timestamp: incident.timestamp || Date.now() / 1000,
    peakG: Number(incident.peakG || 0),
    incidentID,
    mapURL: incident.mapURL || "",
  };
  const writes = {};
  primaryIDs.forEach((uid) => { writes[`users/${uid}/crashAlerts/${incidentID}`] = payload; });
  await db.ref().update(writes);
}

exports.notifyOnCrashIncident = functions.database
  .ref("/crashIncidents/{incidentID}")
  .onCreate(async (snapshot, context) => {
    const incident = snapshot.val();
    if (!incident || incident.status !== "open") return null;
    await Promise.all([
      sendCrashPush(context.params.incidentID, incident),
      writeCrashInboxes(context.params.incidentID, incident),
    ]);
    return null;
  });

// Cloud Scheduler invokes this every two minutes. At most three reminders are
// sent, and an acknowledgement flips status away from open immediately.
exports.escalateUnacknowledgedCrashIncidents = functions.pubsub
  .schedule("every 2 minutes")
  .onRun(async () => {
    const now = Date.now() / 1000;
    const due = await db.ref("crashIncidents").orderByChild("nextEscalationAt").endAt(now).once("value");
    const jobs = [];
    due.forEach((child) => {
      const incident = child.val();
      if (!incident || incident.status !== "open") return;
      const count = Number(incident.escalationCount || 0);
      if (count >= 3) return;
      jobs.push((async () => {
        await sendCrashPush(child.key, incident, true);
        await child.ref.update({ escalationCount: count + 1, nextEscalationAt: now + 120 });
      })());
    });
    await Promise.all(jobs);
    return null;
  });

// MARK: - Solo ride -> notify followers
exports.notifyFollowersOnSoloRideStart = functions.database
  .ref("/users/{uid}/location/isOnline")
  .onUpdate(async (change, context) => {
    const before = change.before.val();
    const after = change.after.val();
    if (before === true || after !== true) return null; // only fire on the false/undefined -> true edge

    const uid = context.params.uid;

    const [nameSnap, followersSnap] = await Promise.all([
      db.ref(`users/${uid}/profile/name`).once("value"),
      db.ref(`users/${uid}/followers`).once("value"),
    ]);

    const riderName = nameSnap.val() || "A rider you follow";
    const followerIds = followersSnap.val() ? Object.keys(followersSnap.val()) : [];
    if (!followerIds.length) return null;

    const recipients = (await Promise.all(followerIds.map(userPushRecipients))).flat();

    return sendPush(
      recipients,
      `🏍️ ${riderName} started a ride`,
      "Tap to open PackRide and see their live location.",
      (id) => db.ref(`users/${id}/fcmToken`)
    );
  });

// MARK: - Community ride -> notify other members
exports.notifyCommunityOnRideStart = functions.database
  .ref("/communities/{communityId}/members/{uid}/isRiding")
  .onUpdate(async (change, context) => {
    const before = change.before.val();
    const after = change.after.val();
    if (before === true || after !== true) return null;

    const { communityId, uid } = context.params;

    const [nameSnap, communityNameSnap, membersSnap] = await Promise.all([
      db.ref(`communities/${communityId}/members/${uid}/name`).once("value"),
      db.ref(`communities/${communityId}/name`).once("value"),
      db.ref(`communities/${communityId}/members`).once("value"),
    ]);

    const riderName = nameSnap.val() || "A member";
    const communityName = communityNameSnap.val() || "your community";
    const membersVal = membersSnap.val() || {};

    const recipients = Object.keys(membersVal)
      .filter((id) => id !== uid)
      .map((id) => ({ id, token: membersVal[id] && membersVal[id].fcmToken }));

    if (!recipients.length) return null;

    return sendPush(
      recipients,
      `🏍️ ${riderName} is riding`,
      `${riderName} just started riding in ${communityName}.`,
      (id) => db.ref(`communities/${communityId}/members/${id}/fcmToken`)
    );
  });

// MARK: - Need Help -> notify whoever it was shared with
//
// Aug 22, 2026 — this was the missing half of Need Help: the client
// (HelpRequestManager.swift) writes /helpRequests/{uid} and any screen that
// happens to be open filters and shows it live, but nothing ever reached a
// recipient whose app was backgrounded or on a different screen. This
// mirrors notifyCommunityOnRideStart above but keyed off Need Help starting
// rather than a ride starting, and fans out to whichever of the three share
// targets (friend / community / group) was actually chosen.
//
// Triggers on .onCreate rather than .onUpdate/.onWrite because start()
// creates this node fresh with .setValue() and stop() deletes the whole
// node with .removeValue() — so onCreate fires exactly once per genuine new
// share, never on the location-only updateChildValues() ticks (lat/lng/
// lastUpdated only) that follow every ~5s while sharing stays live.
exports.notifyOnHelpRequestStart = functions.database
  .ref("/helpRequests/{uid}")
  .onCreate(async (snapshot) => {
    const data = snapshot.val();
    if (!data) return null;

    const { requesterName, requesterDeviceID, targetType, targetID, targetName } = data;
    const title = `🚨 ${requesterName || "Someone"} needs help`;

    if (targetType === "friend") {
      const recipients = await userPushRecipients(targetID);
      if (!recipients.length) return null;
      return sendPush(
        recipients,
        title,
        `${requesterName} shared their live location with you.`,
        (id) => db.ref(`users/${id}/fcmToken`),
        { safety: true, data: { packrideType: "helpRequest" } }
      );
    }

    if (targetType === "community") {
      const membersSnap = await db.ref(`communities/${targetID}/members`).once("value");
      const membersVal = membersSnap.val() || {};
      const recipients = Object.keys(membersVal)
        .filter((id) => id !== requesterDeviceID)
        .map((id) => ({ id, token: membersVal[id] && membersVal[id].fcmToken }));
      if (!recipients.length) return null;
      return sendPush(
        recipients,
        title,
        `${requesterName} shared their live location with ${targetName || "your community"}.`,
        (id) => db.ref(`communities/${targetID}/members/${id}/fcmToken`),
        { safety: true, data: { packrideType: "helpRequest" } }
      );
    }

    if (targetType === "group") {
      // rides/{code}/riders/{deviceID}/fcmToken — written at join time by
      // FirebaseManager.joinRide() (see the Aug 22, 2026 addition there);
      // riders who joined before that fix simply have no token yet and are
      // silently skipped here, same as any other missing-token recipient.
      const ridersSnap = await db.ref(`rides/${targetID}/riders`).once("value");
      const ridersVal = ridersSnap.val() || {};
      const recipients = Object.keys(ridersVal)
        .filter((id) => id !== requesterDeviceID)
        .map((id) => ({ id, token: ridersVal[id] && ridersVal[id].fcmToken }));
      if (!recipients.length) return null;
      return sendPush(
        recipients,
        title,
        `${requesterName} shared their live location with your group ride.`,
        (id) => db.ref(`rides/${targetID}/riders/${id}/fcmToken`),
        { safety: true, data: { packrideType: "helpRequest" } }
      );
    }

    return null;
  });

// A private, recipient-specific inbox for Need Help. This keeps the live
// location stream out of unrelated clients while preserving updates every
// time the requester moves. Admin SDK bypasses client database rules.
async function helpRecipientUIDs(request) {
  if (!request) return [];
  if (request.targetType === "friend") return request.targetID ? [request.targetID] : [];
  if (request.targetType === "group") {
    const riders = (await db.ref(`rides/${request.targetID}/riders`).once("value")).val() || {};
    return [...new Set(Object.values(riders).map((r) => r && r.authUID).filter(Boolean))];
  }
  if (request.targetType === "community") {
    const members = (await db.ref(`communities/${request.targetID}/members`).once("value")).val() || {};
    return [...new Set(Object.values(members).map((m) => m && m.authUID).filter(Boolean))];
  }
  return [];
}

exports.fanoutHelpRequest = functions.database
  .ref("/helpRequests/{requesterUID}")
  .onWrite(async (change, context) => {
    const before = change.before.val();
    const after = change.after.val();
    const request = after || before;
    if (!request) return null;
    const recipients = (await helpRecipientUIDs(request))
      .filter((uid) => uid && uid !== context.params.requesterUID);
    const writes = {};
    recipients.forEach((uid) => {
      writes[`users/${uid}/helpAlerts/${context.params.requesterUID}`] = after || null;
    });
    return Object.keys(writes).length ? db.ref().update(writes) : null;
  });

// MARK: - Community track-layout catalogue
function geoDistanceMeters(a, b) {
  const toRad = (v) => v * Math.PI / 180;
  const lat1 = toRad(a.latitude), lat2 = toRad(b.latitude);
  const dLat = lat2 - lat1, dLon = toRad(b.longitude - a.longitude);
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLon / 2) ** 2;
  return 6371000 * 2 * Math.atan2(Math.sqrt(h), Math.sqrt(1 - h));
}

function safeTrackKey(name, center) {
  const slug = String(name || "track").toLowerCase().normalize("NFKD")
    .replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 55) || "track";
  return `${slug}-${Number(center.latitude).toFixed(3).replace(".", "_")}-${Number(center.longitude).toFixed(3).replace(".", "_")}`;
}

function validPoint(point) {
  return point && Number.isFinite(point.latitude) && Number.isFinite(point.longitude) &&
    Math.abs(point.latitude) <= 90 && Math.abs(point.longitude) <= 180;
}

function routeSimilarityMeters(left, right) {
  if (!left.length || !right.length) return Infinity;
  const sample = left.filter((_, i) => i % Math.max(1, Math.floor(left.length / 40)) === 0);
  return sample.reduce((sum, point) => {
    const nearest = right.reduce((best, candidate) => Math.min(best, geoDistanceMeters(point, candidate)), Infinity);
    return sum + nearest;
  }, 0) / sample.length;
}

exports.processCommunityLayoutSubmission = functions.database
  .ref("/communityLayoutSubmissions/{submissionID}")
  .onCreate(async (snapshot, context) => {
    const value = snapshot.val() || {};
    const route = Array.isArray(value.centerline) ? value.centerline : Object.values(value.centerline || {});
    const reject = async (reason) => snapshot.ref.update({ status: "rejected", rejectionReason: reason, reviewedAt: admin.database.ServerValue.TIMESTAMP });
    if (value.status !== "pending" || !value.createdBy || Number(value.completedLapCount) < 2) return reject("insufficient_evidence");
    if (route.length < 20 || route.length > 240 || route.some((point) => !validPoint(point))) return reject("invalid_centerline");
    if (!validPoint(value.center) || !value.startFinishGate || !validPoint(value.startFinishGate.a) || !validPoint(value.startFinishGate.b)) return reject("invalid_timing_gate");
    if (geoDistanceMeters(route[0], route[route.length - 1]) > 80) return reject("route_not_closed");
    const venueName = String(value.venueName || "").trim().slice(0, 80);
    const layoutName = String(value.layoutName || "").trim().slice(0, 60);
    if (!venueName || !layoutName) return reject("missing_name");

    const venueID = safeTrackKey(venueName, value.center);
    const configurationsRef = db.ref(`tracks/${venueID}/configurations`);
    const configurations = (await configurationsRef.once("value")).val() || {};
    let duplicateID = null;
    for (const [id, config] of Object.entries(configurations)) {
      const existingRoute = Array.isArray(config.centerline) ? config.centerline : Object.values(config.centerline || {});
      if (existingRoute.length >= 20 && routeSimilarityMeters(route, existingRoute) <= 35) { duplicateID = id; break; }
    }

    const writes = {};
    if (duplicateID) {
      const base = `tracks/${venueID}/configurations/${duplicateID}`;
      const current = configurations[duplicateID] || {};
      const alreadyContributed = current.contributors && current.contributors[value.createdBy];
      const confirmationCount = Number(current.confirmationCount || 1) + (alreadyContributed ? 0 : 1);
      writes[`${base}/confirmationCount`] = confirmationCount;
      writes[`${base}/contributors/${value.createdBy}`] = true;
      writes[`${base}/verificationStatus`] = confirmationCount >= 3 ? "community_confirmed" : "community_new";
      writes[`communityLayoutSubmissions/${context.params.submissionID}/matchedLayoutID`] = duplicateID;
    } else {
      const layoutID = context.params.submissionID;
      writes[`tracks/${venueID}/name`] = venueName;
      writes[`tracks/${venueID}/center`] = value.center;
      writes[`tracks/${venueID}/verificationStatus`] = "community";
      writes[`tracks/${venueID}/source`] = "community_phone_gps";
      writes[`tracks/${venueID}/configurations/${layoutID}`] = {
        name: layoutName, centerline: route, startFinishGate: value.startFinishGate,
        sectorGates: value.sectorGates || [], finishGate: value.finishGate || null,
        pitEntryGate: value.pitEntryGate || null, pitExitGate: value.pitExitGate || null,
        verificationStatus: "community_new", confirmationCount: 1,
        contributors: { [value.createdBy]: true }, createdAt: admin.database.ServerValue.TIMESTAMP,
        source: "community_phone_gps",
      };
    }
    writes[`communityLayoutSubmissions/${context.params.submissionID}/status`] = duplicateID ? "matched" : "accepted";
    writes[`communityLayoutSubmissions/${context.params.submissionID}/reviewedAt`] = admin.database.ServerValue.TIMESTAMP;
    return db.ref().update(writes);
  });

// A rider confirms an existing layout simply by selecting it and explicitly
// agreeing that both the route and start/finish line match. The UID-keyed
// confirmation path and contributor check make this idempotent: one rider can
// add at most one confirmation to a configuration.
exports.processCommunityLayoutConfirmation = functions.database
  .ref("/communityLayoutConfirmations/{venueID}/{configurationID}/{uid}")
  .onCreate(async (snapshot, context) => {
    const {venueID, configurationID, uid} = context.params;
    const configRef = db.ref(`tracks/${venueID}/configurations/${configurationID}`);
    await configRef.transaction((config) => {
      if (!config || (config.contributors && config.contributors[uid])) return config;
      const confirmationCount = Number(config.confirmationCount || 1) + 1;
      config.confirmationCount = confirmationCount;
      config.verificationStatus = confirmationCount >= 3 ? "community_confirmed" : "community_new";
      config.contributors = config.contributors || {};
      config.contributors[uid] = true;
      config.lastConfirmedAt = admin.database.ServerValue.TIMESTAMP;
      return config;
    });
    return snapshot.ref.update({processedAt: admin.database.ServerValue.TIMESTAMP});
  });

// MARK: - Voice Comms — Agora token generation
//
// The client (VoiceChatManager.swift) never holds the Agora App Certificate —
// it's the equivalent of a password, and embedding it in the app would let
// anyone extract it from the compiled binary and join/spy on any channel.
// Instead, the client calls this function (a Firebase Callable Function) with
// just a channel name (the group ride code) and gets back a short-lived token
// signed with the certificate, which only ever lives here on the server.
//
// AGORA_APP_ID / AGORA_APP_CERTIFICATE come from functions/.env (see
// functions/.env.example) — never hardcoded, never committed with real
// values.
exports.generateAgoraToken = functions.https.onCall(async (data, context) => {
  if (!context.auth || !context.auth.uid) {
    throw new functions.https.HttpsError("unauthenticated", "Sign in before joining group voice chat.");
  }

  const appId = process.env.AGORA_APP_ID;
  const appCertificate = process.env.AGORA_APP_CERTIFICATE;

  if (!appId || !appCertificate) {
    throw new functions.https.HttpsError(
      "failed-precondition",
      "Agora isn't configured on the server yet — AGORA_APP_ID/AGORA_APP_CERTIFICATE are missing from functions/.env."
    );
  }

  const channelName = String(data && data.channelName || "").trim().toUpperCase();
  if (!/^[A-Z0-9]{4,12}$/.test(channelName)) {
    throw new functions.https.HttpsError("invalid-argument", "A valid group ride code is required.");
  }

  // A ride code is not authorization. Only a currently registered member
  // may mint a token for that ride's Agora channel.
  let authorized = false;
  if (channelName.startsWith("VC")) {
    const roomCode = channelName.slice(2);
    const roomSnapshot = await db.ref(`voiceRooms/${roomCode}`).once("value");
    const room = roomSnapshot.val();
    const member = room && room.members && room.members[context.auth.uid];
    authorized = Boolean(room && room.status === "active" && Number(room.expiresAt || 0) > Date.now() && member && member.status === "accepted");
  } else {
    const memberSnapshot = await db.ref(`rideMembers/${channelName}/${context.auth.uid}`).once("value");
    authorized = memberSnapshot.exists();
  }
  if (!authorized) {
    throw new functions.https.HttpsError("permission-denied", "You are not an approved member of this voice room.");
  }

  // uid 0 lets Agora auto-assign a session ID per joiner — PackRide doesn't
  // need to pin voice-chat identity to a specific numeric UID, since who's in
  // the channel is already tracked separately via the ride's rider list.
  const uid = 0;
  const tokenExpirationInSecond = 3600; // 1 hour — plenty for a ride, re-fetched if it ever runs long
  const privilegeExpirationInSecond = 3600;

  const token = RtcTokenBuilder.buildTokenWithUid(
    appId,
    appCertificate,
    channelName,
    uid,
    RtcRole.PUBLISHER,
    tokenExpirationInSecond,
    privilegeExpirationInSecond
  );

  return { token, appId };
});

const VOICE_CODE_CHARS = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
function voiceCode() {
  let value = "";
  for (let i = 0; i < 6; i++) value += VOICE_CODE_CHARS[Math.floor(Math.random() * VOICE_CODE_CHARS.length)];
  return value;
}

exports.createVoiceRoom = functions.https.onCall(async (data, context) => {
  if (!context.auth) throw new functions.https.HttpsError("unauthenticated", "Sign in to create Ride Comms.");
  const uid = context.auth.uid;
  const name = String(data && data.name || "Rider").trim().slice(0, 60) || "Rider";
  const title = String(data && data.title || "Ride Comms").trim().slice(0, 80) || "Ride Comms";
  let code;
  for (let attempt = 0; attempt < 12; attempt++) {
    const candidate = voiceCode();
    const exists = (await db.ref(`voiceRooms/${candidate}`).once("value")).exists();
    if (!exists) { code = candidate; break; }
  }
  if (!code) throw new functions.https.HttpsError("resource-exhausted", "Couldn't allocate a room code. Try again.");
  const now = Date.now();
  await db.ref(`voiceRooms/${code}`).set({
    code, title, hostUID: uid, hostName: name, status: "active", joinPolicy: "host_approval",
    createdAt: now, expiresAt: now + 12 * 60 * 60 * 1000,
    members: { [uid]: { uid, name, role: "host", status: "accepted", joinedAt: now } }
  });
  return { code, channelName: `VC${code}` };
});

exports.requestVoiceRoomJoin = functions.https.onCall(async (data, context) => {
  if (!context.auth) throw new functions.https.HttpsError("unauthenticated", "Sign in to join Ride Comms.");
  const uid = context.auth.uid;
  const code = String(data && data.code || "").trim().toUpperCase();
  const name = String(data && data.name || "Rider").trim().slice(0, 60) || "Rider";
  if (!/^[A-Z2-9]{6}$/.test(code)) throw new functions.https.HttpsError("invalid-argument", "Enter a valid six-character room code.");
  const ref = db.ref(`voiceRooms/${code}`);
  const room = (await ref.once("value")).val();
  if (!room || room.status !== "active" || Number(room.expiresAt || 0) <= Date.now()) throw new functions.https.HttpsError("not-found", "This Ride Comms room is unavailable or expired.");
  const hostUID = room.hostUID;
  const blocks = await Promise.all([
    db.ref(`users/${uid}/blockedUsers/${hostUID}`).once("value"),
    db.ref(`users/${hostUID}/blockedUsers/${uid}`).once("value")
  ]);
  if (blocks.some((s) => s.exists())) throw new functions.https.HttpsError("permission-denied", "You cannot join this room.");
  if (room.members && room.members[uid] && room.members[uid].status === "accepted") return { status: "accepted", channelName: `VC${code}` };
  await ref.child(`joinRequests/${uid}`).set({ uid, name, status: "pending", requestedAt: Date.now() });
  return { status: "pending" };
});

exports.respondVoiceRoomJoin = functions.https.onCall(async (data, context) => {
  if (!context.auth) throw new functions.https.HttpsError("unauthenticated", "Sign in first.");
  const code = String(data && data.code || "").trim().toUpperCase();
  const requesterUID = String(data && data.requesterUID || "").trim();
  const approve = Boolean(data && data.approve);
  const roomRef = db.ref(`voiceRooms/${code}`);
  const room = (await roomRef.once("value")).val();
  if (!room || room.hostUID !== context.auth.uid) throw new functions.https.HttpsError("permission-denied", "Only the room host can approve riders.");
  const request = room.joinRequests && room.joinRequests[requesterUID];
  if (!request) throw new functions.https.HttpsError("not-found", "That request is no longer pending.");
  const updates = {};
  updates[`voiceRooms/${code}/joinRequests/${requesterUID}`] = null;
  updates[`voiceRooms/${code}/members/${requesterUID}`] = {
    uid: requesterUID,
    name: request.name || "Rider",
    role: "rider",
    status: approve ? "accepted" : "rejected",
    joinedAt: approve ? Date.now() : null,
    respondedAt: Date.now()
  };
  await db.ref().update(updates);
  return { status: approve ? "accepted" : "rejected" };
});

exports.leaveVoiceRoom = functions.https.onCall(async (data, context) => {
  if (!context.auth) throw new functions.https.HttpsError("unauthenticated", "Sign in first.");
  const code = String(data && data.code || "").trim().toUpperCase();
  const roomRef = db.ref(`voiceRooms/${code}`);
  const room = (await roomRef.once("value")).val();
  if (!room) return { status: "ended" };
  if (room.hostUID === context.auth.uid) {
    await roomRef.update({ status: "ended", endedAt: Date.now() });
  } else {
    await roomRef.child(`members/${context.auth.uid}`).remove();
    await roomRef.child(`joinRequests/${context.auth.uid}`).remove();
  }
  return { status: room.hostUID === context.auth.uid ? "ended" : "left" };
});


/**
 * sendFeedbackEmail
 *
 * Watches /feedback/{feedbackID} (see database.rules.json — append-only,
 * no client read access) and emails the submitted text straight to Karthik.
 * Both PackRide clients write here from Profile -> Send Feedback:
 *   { senderUID, senderName, senderEmail, platform: "ios" | "android",
 *     message, createdAt: ServerValue.TIMESTAMP }
 *
 * Sends via a Gmail account through nodemailer, configured with a local
 * .env file (functions.config() is deprecated/blocked by the current
 * Firebase CLI). One-time setup: create packride-functions/functions/.env
 * containing —
 *   FEEDBACK_GMAIL_USER=youraddress@gmail.com
 *   FEEDBACK_GMAIL_PASS=16-character app password
 *   FEEDBACK_TO_EMAIL=karthikgundavarapu@gmail.com
 * (FEEDBACK_GMAIL_PASS must be a Gmail *App Password* — Google Account ->
 * Security -> 2-Step Verification -> App passwords — not your normal Gmail
 * password, which Google will reject for SMTP login. FEEDBACK_TO_EMAIL is
 * optional; it defaults to karthikgundavarapu@gmail.com below if unset.
 * .env is gitignored — never commit it.)
 * Then redeploy: firebase deploy --only functions:sendFeedbackEmail
 */
let feedbackMailTransport = null;
function getFeedbackMailTransport() {
  if (feedbackMailTransport) return feedbackMailTransport;
  const user = process.env.FEEDBACK_GMAIL_USER;
  const pass = process.env.FEEDBACK_GMAIL_PASS;
  if (!user || !pass) return null;
  feedbackMailTransport = nodemailer.createTransport({
    service: "gmail",
    auth: { user, pass }
  });
  return feedbackMailTransport;
}

exports.sendFeedbackEmail = functions.database
  .ref("/feedback/{feedbackID}")
  .onCreate(async (snapshot) => {
    const feedback = snapshot.val() || {};
    const transport = getFeedbackMailTransport();
    if (!transport) {
      console.error(
        "sendFeedbackEmail: missing FEEDBACK_GMAIL_USER/FEEDBACK_GMAIL_PASS — " +
        "create packride-functions/functions/.env with those two values and redeploy."
      );
      return null;
    }
    const toEmail = process.env.FEEDBACK_TO_EMAIL || "karthikgundavarapu@gmail.com";
    const platform = feedback.platform === "android" ? "Android" : feedback.platform === "ios" ? "iOS" : "Unknown platform";
    const senderName = feedback.senderName || "A PackRide rider";
    const senderEmail = feedback.senderEmail || "";
    const message = feedback.message || "";
    const submittedAt = new Date().toLocaleString("en-US", { timeZone: "America/New_York" });

    try {
      await transport.sendMail({
        from: `"PackRide Feedback" <${process.env.FEEDBACK_GMAIL_USER}>`,
        to: toEmail,
        replyTo: senderEmail || undefined,
        subject: `PackRide feedback (${platform}) from ${senderName}`,
        text:
          `From: ${senderName}${senderEmail ? ` <${senderEmail}>` : ""}\n` +
          `Platform: ${platform}\n` +
          `Sender UID: ${feedback.senderUID || "unknown"}\n` +
          `Submitted: ${submittedAt}\n\n${message}`
      });
    } catch (e) {
      console.error("sendFeedbackEmail: send failed", e);
    }
    return null;
  });
