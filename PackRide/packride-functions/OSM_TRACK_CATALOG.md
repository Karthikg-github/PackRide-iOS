# OpenStreetMap track-catalog import

PackRide imports named, closed `highway=raceway` centerlines. An explicit
nearby `raceway=start-finish` or `motorsport=start-finish` node is included
when available; otherwise the record is marked `geometry_only` and the rider
places the line in Track Mode. Pit
lanes, service roads, areas, horse tracks, dog tracks, and RC tracks are
excluded. The importer never invents a timing line.

Use regional OSM extracts for a worldwide production catalogue. Public
Overpass servers are intended for modest, non-parallel jobs and should not be
used as an app runtime dependency or hammered with a single planet-scale job.

For a bounded Overpass export, use this query and replace `{{bbox}}`:

```
[out:json][timeout:300];
(
  way["highway"="raceway"]({{bbox}});
  node["raceway"="start-finish"]({{bbox}});
  node["motorsport"="start-finish"]({{bbox}});
);
out tags geom;
```

Generate and inspect a dry-run catalogue:

```
cd functions
npm run import-osm-tracks -- region-overpass.json --output region-catalog.json
```

After visual review, authenticated production import is explicit:

```
npm run import-osm-tracks -- region-overpass.json --write
```

OSM-derived records retain source element IDs, URLs, and the required
`© OpenStreetMap contributors, ODbL 1.0` attribution. Existing official or
community records are never overwritten by the bulk importer.
