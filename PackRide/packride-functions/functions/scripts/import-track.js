#!/usr/bin/env node

/*
 * PackRide reviewed-track importer.
 *
 * The official URL supplies provenance and configuration naming. Geometry
 * must come from coordinates: an OSM way/relation exported as GeoJSON, or a
 * reviewed GeoJSON file. Website artwork is never copied into Firebase.
 *
 * Usage:
 *   npm run import-track -- path/to/track.json          # validate/preview
 *   npm run import-track -- path/to/track.json --write  # write to Firebase
 *
 * --write uses Application Default Credentials (firebase login or
 * GOOGLE_APPLICATION_CREDENTIALS) and the project in GCLOUD_PROJECT.
 */

const fs = require("fs");
const path = require("path");
const admin = require("firebase-admin");

function fail(message) {
  console.error(`Track import failed: ${message}`);
  process.exit(1);
}

function number(value, label) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) fail(`${label} must be a number`);
  return parsed;
}

function point(value, label) {
  if (!value || typeof value !== "object") fail(`${label} is missing`);
  const latitude = number(value.latitude ?? value.lat, `${label}.latitude`);
  const longitude = number(value.longitude ?? value.lng ?? value.lon, `${label}.longitude`);
  if (Math.abs(latitude) > 90 || Math.abs(longitude) > 180) fail(`${label} is outside valid coordinate bounds`);
  return {latitude, longitude};
}

function geoJSONCoordinates(file, featureName) {
  const resolved = path.resolve(path.dirname(manifestPath), file);
  const root = JSON.parse(fs.readFileSync(resolved, "utf8"));
  const features = root.type === "FeatureCollection" ? root.features : [root.type === "Feature" ? root : {geometry: root, properties: {}}];
  const feature = featureName
    ? features.find((item) => String(item.properties?.name || "").toLowerCase() === featureName.toLowerCase())
    : features[0];
  if (!feature) fail(`GeoJSON feature '${featureName}' was not found in ${file}`);
  const geometry = feature.geometry;
  let coordinates;
  if (geometry?.type === "LineString") coordinates = geometry.coordinates;
  else if (geometry?.type === "MultiLineString") coordinates = geometry.coordinates.flat();
  else if (geometry?.type === "Polygon") coordinates = geometry.coordinates[0];
  else fail(`${file} must contain LineString, MultiLineString, or Polygon geometry`);
  return coordinates.map((item, index) => point({longitude: item[0], latitude: item[1]}, `geometry[${index}]`));
}

function distanceMeters(a, b) {
  const radians = (degrees) => degrees * Math.PI / 180;
  const dLat = radians(b.latitude - a.latitude);
  const dLon = radians(b.longitude - a.longitude);
  const lat1 = radians(a.latitude);
  const lat2 = radians(b.latitude);
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLon / 2) ** 2;
  return 6371000 * 2 * Math.atan2(Math.sqrt(h), Math.sqrt(1 - h));
}

function decimate(points, maximum = 240) {
  if (points.length <= maximum) return points;
  const stride = Math.ceil(points.length / maximum);
  const result = points.filter((_, index) => index % stride === 0);
  if (result[result.length - 1] !== points[points.length - 1]) result.push(points[points.length - 1]);
  return result;
}

function slug(value) {
  return String(value).toLowerCase().normalize("NFKD").replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 70);
}

const args = process.argv.slice(2);
const manifestArg = args.find((value) => !value.startsWith("--"));
if (!manifestArg) fail("provide a track manifest JSON file");
const manifestPath = path.resolve(manifestArg);
const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
const venueName = String(manifest.venueName || "").trim();
if (!venueName) fail("venueName is required");
if (!/^https:\/\//.test(manifest.officialUrl || "")) fail("officialUrl must be an HTTPS URL");
const center = point(manifest.center, "center");
if (!Array.isArray(manifest.configurations) || !manifest.configurations.length) fail("at least one configuration is required");
if (manifest.configurations.filter((item) => item.isDefault).length !== 1) fail("exactly one configuration must have isDefault=true");

const configurations = {};
for (const item of manifest.configurations) {
  const name = String(item.name || "").trim();
  if (!name) fail("every configuration needs a name");
  const id = slug(item.id || name);
  if (!id || configurations[id]) fail(`configuration id '${id}' is empty or duplicated`);
  let centerline = geoJSONCoordinates(item.geoJSONFile, item.geoJSONFeatureName);
  centerline = decimate(centerline);
  if (centerline.length < 20) fail(`${name} needs at least 20 geometry points`);
  if (distanceMeters(centerline[0], centerline[centerline.length - 1]) > 100) fail(`${name} geometry is not a closed circuit`);
  const a = point(item.startFinish?.a, `${name}.startFinish.a`);
  const b = point(item.startFinish?.b, `${name}.startFinish.b`);
  if (distanceMeters(a, b) < 3 || distanceMeters(a, b) > 80) fail(`${name} start/finish gate must be 3–80 metres wide`);
  configurations[id] = {
    name,
    isDefault: Boolean(item.isDefault),
    centerline,
    startFinishGate: {a, b, direction: item.startFinish.direction === "negative_to_positive" ? "negative_to_positive" : "positive_to_negative"},
    sectorGates: [],
    verificationStatus: "official_reviewed",
    confirmationCount: 0,
    source: "official_import",
    sourceURL: manifest.officialUrl,
    geometrySource: String(item.geometrySource || "reviewed_geojson"),
    reviewedAt: admin.database.ServerValue.TIMESTAMP,
    schemaVersion: 1,
  };
}

const venueID = manifest.id || `${slug(venueName)}-${center.latitude.toFixed(3).replace(".", "_")}-${center.longitude.toFixed(3).replace(".", "_")}`;
const payload = {
  name: venueName,
  center,
  officialURL: manifest.officialUrl,
  source: "official_import",
  verificationStatus: "official_reviewed",
  reviewedAt: admin.database.ServerValue.TIMESTAMP,
  schemaVersion: 1,
  configurations,
};

console.log(JSON.stringify({venueID, ...payload}, null, 2));
if (!args.includes("--write")) {
  console.log("\nPreview only. Re-run with --write after reviewing the coordinates and start/finish gates.");
  process.exit(0);
}

admin.initializeApp();
admin.database().ref(`tracks/${venueID}`).set(payload)
  .then(() => { console.log(`Imported ${venueName} as tracks/${venueID}`); process.exit(0); })
  .catch((error) => fail(error.message));
