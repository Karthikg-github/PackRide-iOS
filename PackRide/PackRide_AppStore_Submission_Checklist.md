# PackRide — App Store Submission Checklist

This covers everything needed to submit PackRide for public App Store review, beyond the TestFlight build you already have working. Full review is slower and stricter than TestFlight (no Beta App Review shortcut) — budget 1-3 days for the first review, sometimes longer if anything gets flagged.

---

## 0. Important — code change made today

**Added a "Delete Account" feature** (`ProfileView.swift` + `AuthManager.swift`). Apple's App Store Review Guideline 5.1.1(v) requires any app that lets people create an account to also let them delete it, entirely within the app — PackRide didn't have this before, and it's a near-certain rejection reason without it. It's now a button at the bottom of the Profile screen, below Sign Out, with a confirmation prompt. Paste both files into Xcode and rebuild before submitting.

---

## 1. Host the Privacy Policy (required — blocks submission without it)

I've drafted the full text in **PackRide_Privacy_Policy.md**, delivered alongside this checklist. Apple requires a **live URL** to this policy (not just an in-app screen). Easiest free options:

- **GitHub Pages** — if you don't already have a GitHub account, create one, make a new repository, enable Pages in its settings, and add the policy as `index.html` or `index.md`. Free, gives you a URL like `https://yourname.github.io/packride-privacy`.
- **Google Sites** — sites.google.com, free, no coding — paste the text in, publish, get a URL.
- **Notion (public page)** — paste the text into a Notion page, click Share → "Share to web" to get a public URL.

Whichever you use, fill in the `[ADD YOUR CONTACT EMAIL HERE]` placeholder at the bottom of the policy before publishing it. Once it's live, save the URL — you'll paste it into App Store Connect in step 4.

---

## 2. App Store screenshots (required)

Apple requires screenshots for at least the 6.7" iPhone size (iPhone 15/16 Pro Max class). Easiest way to get them:

1. In Xcode, run PackRide on the **iPhone 16 Pro Max simulator** (Simulator menu → pick that device if it's not already selected).
2. Navigate to the screens you want to show off — good picks: the map with a route + speed limit badge, the Ride Feed, a Community dashboard, the ride summary screen.
3. On each screen, press **⌘S** in the Simulator (or Simulator menu → File → Save Screen) — this saves a full-resolution PNG to your Desktop, automatically sized correctly for the App Store.
4. You need a minimum of 3 screenshots for the 6.7" size (up to 10 allowed). Pick your best 3-5.

---

## 3. App Store Connect — App Information

In App Store Connect → your PackRide app → **App Information**:

- **Name:** PackRide (or "PackRide App" if "PackRide" is taken, per the handover doc — you may have already resolved this).
- **Subtitle** (30 characters max) — suggestion: `Ride together, ride smart`
- **Category:** Primary: **Travel**. Secondary (optional): **Social Networking**.
- **Privacy Policy URL:** the link from step 1.

---

## 4. App Store Connect — Version Information (for this release)

- **Promotional text** (170 chars, editable anytime without re-review):
  `Track rides, ride with friends in real time, join riding communities, and share your routes — built for motorcycle riders.`

- **Description** (draft, feel free to edit):

  > PackRide is a social app built for motorcycle riders. Track your rides with GPS, see live speed limits and road names as you ride, and get weather along your route. Ride together with turn-by-turn navigation and see your group's live location on the map. Join or create a riding community to stay connected with other local riders, get crash alerts if something goes wrong, and share your rides on the Ride Feed for people who follow you to see.
  >
  > Features:
  > • GPS ride tracking with speed, distance, and route recording
  > • Turn-by-turn navigation with live speed limit and road name display
  > • Group rides with live rider locations on the map
  > • Riding communities — join or create one, see who's riding now
  > • Crash detection with automatic alerts to your group
  > • Ride Feed — share rides, follow other riders, see their routes
  > • Weather along your route
  > • Emergency contact info, stored securely on your device

- **Keywords** (100 chars, comma-separated, no spaces after commas):
  `motorcycle,riding,gps,tracker,route,group ride,navigation,biker,community,speed limit`

- **Support URL:** you need a working URL here too — a simple page (or even a GitHub repo README, or a Google Form) works. Required by Apple.
- **Marketing URL:** optional, can leave blank.

---

## 5. App Privacy ("Nutrition Label") questionnaire

In App Store Connect → **App Privacy**, Apple asks you to declare every data type the app collects. Based on what PackRide actually does, here's how to answer:

| Data Type | Collected? | Linked to identity? | Used for | Notes |
|---|---|---|---|---|
| **Location — Precise Location** | Yes | Yes | App Functionality | Core ride tracking/live location |
| **Contact Info — Email Address** | Yes | Yes | App Functionality | Login |
| **Identifiers — User ID** | Yes | Yes | App Functionality | Firebase Auth UID / device ID |
| **User Content — Photos or Videos** | Yes | Yes | App Functionality | Optional profile, banner, and ride-feed photos |
| **User Content — Other User Content** | Yes | Yes | App Functionality | Ride posts, comments, routes, and community content |
| **Usage Data** | No | — | — | No analytics currently collected |
| **Diagnostics** | No | — | — | No crash reporting currently wired up |
| **Contacts** | No | — | — | Only accessed via the system contact *picker*, never stored on our servers (see Privacy Policy) |

Answer "No" for anything not listed above (Health, Financial Info, Browsing History, Search History, Purchases, Sensitive Info) — PackRide doesn't collect any of those.

---

## 6. Age Rating questionnaire

Apple's age rating form asks about content categories. For PackRide, answer "None" / "No" to all the violence, sexual content, gambling, and substance-related questions — the app has none of that. The one to pay attention to:

- **"Does your app include user-generated content?"** → **Yes** (Ride Feed posts, photos, and comments are user-generated; PackRide includes reporting and rider blocking controls).

This will likely land PackRide at a **12+** rating (unmoderated user-generated content typically triggers this), rather than 4+. That's normal for any app with a social feed and isn't something to fight — just answer honestly.

---

## 7. Pricing and Availability

- **Price:** Free (unless you've decided otherwise — nothing in the current build charges for anything).
- **Availability:** choose which countries/regions to list in — "All countries" is fine for a first release, or narrow it to your home country if you'd rather start small.

---

## 8. Before you hit Submit

- [ ] Delete Account feature pasted into Xcode and rebuilt (step 0 above)
- [ ] Privacy Policy published at a real URL, contact email filled in
- [ ] At least 3 screenshots (6.7" size) uploaded
- [ ] App description, keywords, support URL filled in
- [ ] App Privacy questionnaire completed
- [ ] Age Rating questionnaire completed
- [ ] Pricing/availability set
- [ ] The build you already uploaded (the one that cleared "Missing Compliance") is selected under **Build** in the version page
- [ ] Click **Submit for Review**

After submitting, status moves through **Waiting for Review → In Review → Ready for Sale** (or occasionally **Rejected**, with Apple's specific reason — if that happens, send me the rejection message and we'll fix it). Once it's live, anyone (including your friend) can download PackRide straight from the App Store.
