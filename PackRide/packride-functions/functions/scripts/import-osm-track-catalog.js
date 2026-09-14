#!/usr/bin/env node

/*
 * Builds PackRide's worldwide track catalogue from an Overpass JSON export.
 * Only named, closed highway=raceway ways with a nearby explicitly tagged
 * raceway/motorsport start-finish node are accepted. Nothing is guessed.
 *
 * Usage:
 *   node scripts/import-osm-track-catalog.js overpass.json --output catalog.json
 *   node scripts/import-osm-track-catalog.js overpass.json --write
 *
 * Production writes require Application Default Credentials and an explicit
 * --write. Existing community/official-reviewed configurations are preserved.
 */

const fs = require("fs");
const path = require("path");

const args = process.argv.slice(2);
const inputArg = args.find((arg) => !arg.startsWith("--"));
if (!inputArg) {
  console.error("Provide an Overpass JSON file. See OSM_TRACK_CATALOG.md.");
  process.exit(1);
}
const option = (name) => {
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : undefined;
};
const raw = JSON.parse(fs.readFileSync(path.resolve(inputArg), "utf8"));
const elements = Array.isArray(raw.elements) ? raw.elements : [];

const radians = (degrees) => degrees * Math.PI / 180;
const distance = (a, b) => {
  const dLat = radians(b.latitude - a.latitude);
  const dLon = radians(b.longitude - a.longitude);
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(radians(a.latitude)) *
    Math.cos(radians(b.latitude)) * Math.sin(dLon / 2) ** 2;
  return 6371000 * 2 * Math.atan2(Math.sqrt(h), Math.sqrt(1 - h));
};
const slug = (value) => String(value).toLowerCase().normalize("NFKD")
  .replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 70);
const point = (value) => ({latitude: Number(value.lat), longitude: Number(value.lon)});
const startFinishNode = (element) => {
  const value = String(element.tags?.motorsport || element.tags?.raceway || "").toLowerCase();
  return element.type === "node" && ["start-finish", "start_finish", "start/finish"].includes(value);
};
const forbidden = (tags) => {
  const detail = `${tags.raceway || ""} ${tags.service || ""} ${tags.sport || ""}`.toLowerCase();
  return /pit|service|escape|run.?off|horse|equestrian|dog_racing|rc_car|cycling|bicycle|roller_skating|skateboard/.test(detail) || tags.area === "yes";
};
const forbiddenName = (name) => /(pit.?lane|\bpits?\b|skate|cycling|cycle|wieler|bicycle|rc.?track)/i.test(name);
const decimate = (points, maximum = 240) => {
  if (points.length <= maximum) return points;
  const stride = Math.ceil(points.length / maximum);
  const result = points.filter((_, index) => index % stride === 0);
  if (result[result.length - 1] !== points[points.length - 1]) result.push(points[points.length - 1]);
  return result;
};
const offset = (origin, eastMeters, northMeters) => ({
  latitude: origin.latitude + northMeters / 111320,
  longitude: origin.longitude + eastMeters / (111320 * Math.max(.15, Math.cos(radians(origin.latitude)))),
});

const markers = elements.filter(startFinishNode).map((node) => ({...point(node), id: node.id}));
const tracks = {};
const rejected = {unnamed: 0, open: 0, noMarker: 0, invalid: 0};

for (const way of elements) {
  if (way.type !== "way" || way.tags?.highway !== "raceway" || forbidden(way.tags || {})) continue;
  const name = String(way.tags?.name || "").trim();
  if (!name) { rejected.unnamed++; continue; }
  if (forbiddenName(name)) { rejected.invalid++; continue; }
  let centerline = (way.geometry || []).map(point).filter((p) => Number.isFinite(p.latitude) && Number.isFinite(p.longitude));
  if (centerline.length < 20) { rejected.invalid++; continue; }
  if (distance(centerline[0], centerline[centerline.length - 1]) > 35) { rejected.open++; continue; }

  let nearest;
  let nearestIndex = -1;
  let nearestDistance = Infinity;
  for (const marker of markers) {
    centerline.forEach((candidate, index) => {
      const meters = distance(marker, candidate);
      if (meters < nearestDistance) { nearest = marker; nearestIndex = index; nearestDistance = meters; }
    });
  }
  let gate;
  if (nearest && nearestDistance <= 60) {
    const before = centerline[(nearestIndex - 2 + centerline.length) % centerline.length];
    const after = centerline[(nearestIndex + 2) % centerline.length];
    const meanLat = radians((before.latitude + after.latitude) / 2);
    const tangentEast = (after.longitude - before.longitude) * Math.cos(meanLat) * 111320;
    const tangentNorth = (after.latitude - before.latitude) * 111320;
    const length = Math.hypot(tangentEast, tangentNorth);
    if (length >= 1) {
      const normalEast = -tangentNorth / length * 15;
      const normalNorth = tangentEast / length * 15;
      gate = {a: offset(nearest, normalEast, normalNorth), b: offset(nearest, -normalEast, -normalNorth), direction: "positive_to_negative"};
    }
  }
  if (!gate) rejected.noMarker++;
  centerline = decimate(centerline);

  const venueID = `osm-${way.id}`;
  const layoutName = String(way.tags?.["name:config"] || way.tags?.ref || "Default").trim();
  const configuration = {
    name: layoutName, isDefault: true, centerline, sectorGates: [],
    verificationStatus: gate ? "osm_sourced" : "geometry_only", confirmationCount: 0,
    source: "openstreetmap", geometrySource: `OSM way ${way.id}`,
    sourceURL: `https://www.openstreetmap.org/way/${way.id}`,
    attribution: "© OpenStreetMap contributors, ODbL 1.0", schemaVersion: 1,
  };
  if (gate) {
    configuration.startFinishGate = gate;
    configuration.startFinishSource = `OSM node ${nearest.id}`;
  }
  tracks[venueID] = {
    name,
    center: {
      latitude: centerline.reduce((sum, item) => sum + item.latitude, 0) / centerline.length,
      longitude: centerline.reduce((sum, item) => sum + item.longitude, 0) / centerline.length,
    },
    officialURL: `https://www.openstreetmap.org/way/${way.id}`,
    source: "openstreetmap",
    verificationStatus: gate ? "osm_sourced" : "geometry_only",
    attribution: "© OpenStreetMap contributors, ODbL 1.0",
    osmWayID: way.id,
    schemaVersion: 1,
    configurations: {
      [slug(layoutName) || "default"]: configuration,
    },
  };
}

const output = option("--output");
const withTimingLine = Object.values(tracks).filter((track) => Object.values(track.configurations)[0].startFinishGate).length;
const report = {accepted: Object.keys(tracks).length, withTimingLine, geometryOnly: Object.keys(tracks).length - withTimingLine, rejected, startFinishMarkers: markers.length};
if (output) fs.writeFileSync(path.resolve(output), JSON.stringify({tracks, report}, null, 2));
console.log(JSON.stringify(report, null, 2));

if (!args.includes("--write")) {
  console.log("Dry run only. Inspect the generated catalogue before using --write.");
  process.exit(0);
}

const admin = require("firebase-admin");
admin.initializeApp();
const root = admin.database().ref("tracks");
Promise.all(Object.entries(tracks).map(async ([id, payload]) => {
  const ref = root.child(id);
  const existing = (await ref.get()).val();
  if (existing && existing.source !== "openstreetmap") return "preserved";
  await ref.set({...payload, reviewedAt: admin.database.ServerValue.TIMESTAMP});
  return "written";
})).then((results) => {
  console.log(JSON.stringify({written: results.filter((v) => v === "written").length, preserved: results.filter((v) => v === "preserved").length}));
}).catch((error) => { console.error(error); process.exitCode = 1; });
