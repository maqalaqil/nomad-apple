import maplibregl from 'maplibre-gl';
import 'maplibre-gl/dist/maplibre-gl.css';
import { Protocol, PMTiles } from 'pmtiles';
import './style.css';

const post = (type, body = {}) => window.webkit?.messageHandlers?.nomadMap?.postMessage({type, ...body});
const protocol = new Protocol();
maplibregl.addProtocol('pmtiles', protocol.tile);
const map = new maplibregl.Map({
  container: 'map', center: [0, 20], zoom: 1,
  style: {version: 8, sources: {}, layers: [{id: 'background', type: 'background', paint: {'background-color': '#e2dfda'}}]},
  attributionControl: {compact: true}, maxZoom: 22,
});
map.addControl(new maplibregl.NavigationControl(), 'top-right');
map.addControl(new maplibregl.ScaleControl(), 'bottom-left');
map.on('click', event => post('coordinate', {latitude: event.lngLat.lat, longitude: event.lngLat.lng}));
let lastError = '';
map.on('error', event => {
  const message = event.error?.message || 'The map could not render a local resource.';
  if (message !== lastError) { lastError = message; post('error', {message}); }
});
let revision = 0, currentArchiveKey = '', hasFitted = false, markers = [];
const cache = new Map();
const templatePromise = fetch('nomad-map://assets/nomad-base-styles.json').then(response => {
  if (!response.ok) throw Error('Bundled map style is missing.');
  return response.json();
});
function setMarkers(places) {
  markers.forEach(marker => marker.remove()); markers = [];
  for (const place of places) {
    const content = document.createElement('div');
    const title = document.createElement('strong'); title.textContent = place.name;
    const notes = document.createElement('p'); notes.textContent = place.notes;
    content.append(title, notes);
    markers.push(new maplibregl.Marker({color: /^#[\da-f]{6}$/i.test(place.color) ? place.color : '#cf632c'})
      .setLngLat([place.longitude, place.latitude]).setPopup(new maplibregl.Popup().setDOMContent(content)).addTo(map));
  }
}
async function configure(configuration) {
  setMarkers(configuration.places || []);
  const key = configuration.archives.map(item => item.id).join(',');
  if (key === currentArchiveKey && hasFitted) return;
  currentArchiveKey = key;
  const mine = ++revision;
  const template = await templatePromise;
  const sources = {}, layers = template.layers.filter(layer => !layer.source).map(layer => structuredClone(layer));
  let first;
  for (const archive of configuration.archives) {
    const id = archive.id.toLowerCase();
    const url = `nomad-map://archive/${id}.pmtiles`;
    let pm = cache.get(url);
    if (!pm) { pm = new PMTiles(url); protocol.add(pm); cache.set(url, pm); }
    const [header, metadata] = await Promise.all([pm.getHeader(), pm.getMetadata()]);
    if (mine !== revision) return;
    first ||= header;
    // Archive metadata is untrusted. Convert attribution to plain escaped text.
    const attribution = String(metadata.attribution || archive.name || 'Offline PMTiles')
      .replace(/<[^>]*>/g, '').replaceAll('&copy;', '©').replaceAll('&amp;', '&').replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
    const sourceID = `archive-${id}`;
    const source = {url: `pmtiles://${url}`, attribution, minzoom: header.minZoom, maxzoom: header.maxZoom};
    if (header.tileType === 1) {
      const fields = metadata.vector_layers?.find(layer => layer.id === 'roads')?.fields || {};
      if (fields['pmap:kind'] && !fields.kind) throw Error(`${archive.name} uses the older pmap:kind vector schema. This build supports the NOMAD/Protomaps kind schema; convert the archive or use a matching style.`);
      sources[sourceID] = {...source, type: 'vector'};
      const available = new Set((metadata.vector_layers || []).map(layer => layer.id));
      let matched = 0;
      for (const layer of template.layers.filter(layer => layer.source)) {
        if (available.size && !available.has(layer['source-layer'])) continue;
        layers.push({...structuredClone(layer), id: `${sourceID}-${layer.id}`, source: sourceID}); matched++;
      }
      if (!matched) throw Error(`${archive.name} uses a different vector schema. Import a Protomaps/NOMAD archive, or supply a compatible style in a future build.`);
    } else {
      sources[sourceID] = {...source, type: 'raster', tileSize: 256};
      layers.push({id: sourceID, type: 'raster', source: sourceID});
    }
  }
  if (mine !== revision) return;
  map.setStyle({version: 8, sources, layers,
    sprite: 'nomad-map://assets/basemaps-assets/sprites/v4/light',
    glyphs: 'nomad-map://assets/basemaps-assets/fonts/{fontstack}/{range}.pbf'});
  if (first && !hasFitted) {
    map.fitBounds([[first.minLon, first.minLat], [first.maxLon, first.maxLat]], {padding: 35, maxZoom: 14, duration: 0});
    hasFitted = true;
  }
  post('status', {message: configuration.archives.length ? `${configuration.archives.length} local archive${configuration.archives.length === 1 ? '' : 's'} · tap map to save a place` : 'Import a PMTiles archive to see an offline map.'});
}
window.nomadMap = {
  configure: async config => { try { await configure(config); } catch (error) { post('error', {message: error.message}); throw error; } },
  fly: (latitude, longitude) => map.flyTo({center: [longitude, latitude], zoom: Math.max(map.getZoom(), 13)}),
  map,
};
map.on('load', () => post('ready'));
map.on('idle', () => post('rendered', {features: map.queryRenderedFeatures().length}));
