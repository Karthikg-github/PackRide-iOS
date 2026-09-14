# Reviewed track importer

The importer stores coordinate data, not copyrighted website artwork. Use an
official circuit page to verify layout names, the default configuration,
direction, and start/finish position. Obtain geometry from OpenStreetMap or a
licensed GPX/KML/GeoJSON source, convert it to GeoJSON, and visually align it
with satellite imagery before importing.

1. Copy `functions/scripts/example-track.json` and fill in the venue data.
2. Export each configuration as a closed GeoJSON line with at least 20 points.
3. Preview and validate:

   `npm run import-track -- functions/scripts/my-track.json`

4. Inspect the printed coordinates and gate carefully.
5. Import only after review:

   `npm run import-track -- functions/scripts/my-track.json --write`

Every imported configuration records its official source URL, geometry source,
review time, default status, and `official_reviewed` verification state.
