const grid = document.querySelector("#catalog-list");
const status = document.querySelector("#result-status");
const emptyState = document.querySelector("#empty-state");
const errorState = document.querySelector("#error-state");
const search = document.querySelector("#catalog-search");
const sort = document.querySelector("#catalog-sort");
const filterButtons = [...document.querySelectorAll("[data-track]")];
const template = document.querySelector("#image-row-template");
const variantTemplate = document.querySelector("#image-variant-template");

// Images publish through the verity.supply proxy, which mirrors the build
// registry digest for digest.
const BUILD_REGISTRY = /ghcr\.io\/tektum\//g;
const PUBLIC_REGISTRY = "verity.supply/";

// Build-date tags look like "0-20260807" (YYYYMMDD suffix).
const DATE_TAG = /-(\d{8})$/;

let images = [];
let groups = [];
let activeTrack = "all";
// Tracks the slug of the currently expanded row so it survives re-renders
// and round-trips through the URL. Empty string means nothing is open.
let openSlug = "";
// Only the initial load should scroll to a restored row; typing/filtering
// re-renders should not yank the viewport around.
let firstRender = true;

function published(value) {
  return value.replace(BUILD_REGISTRY, PUBLIC_REGISTRY);
}

function shortDigest(digest) {
  return `${digest.slice(0, 14)}…`;
}

function setText(selector, value) {
  const element = document.querySelector(selector);
  if (element) element.textContent = String(value);
}

// Most severe first. The catalog also emits "negligible", which the design
// system's ramp does not name; it sits below low and above unknown here.
const SEVERITY_ORDER = ["critical", "high", "medium", "low", "negligible", "unknown"];

function severityCounts(image) {
  return image.scan.final ?? image.scan.all ?? {};
}

function observedFindings(image) {
  return Object.values(severityCounts(image)).reduce((total, count) => total + Number(count), 0);
}

// Ranked severities actually present, so a row can lead with its worst.
function presentSeverities(image) {
  const counts = severityCounts(image);
  return SEVERITY_ORDER.filter((severity) => Number(counts[severity]) > 0).map((severity) => ({
    severity,
    count: Number(counts[severity]),
  }));
}

function severityBadge(severity, count, label) {
  const badge = document.createElement("span");
  badge.className = "sev-badge";
  badge.dataset.severity = severity;
  const dot = document.createElement("span");
  dot.className = "sev-dot";
  dot.setAttribute("aria-hidden", "true");
  const text = document.createElement("span");
  text.textContent = label ?? severity.toUpperCase();
  badge.append(dot, text);
  if (count !== undefined) {
    const value = document.createElement("span");
    value.className = "sev-count";
    value.textContent = String(count);
    badge.append(value);
  }
  return badge;
}

// Every published image passes the zero-fixable policy. Keep that actionable
// status primary; the full unfixable severity breakdown stays in the detail.
function fillFindings(element, image) {
  element.replaceChildren(severityBadge("none", undefined, "0 FIXABLE"));
  const present = presentSeverities(image);
  if (present.length === 0) {
    element.title = "No known vulnerabilities";
    return;
  }
  const total = observedFindings(image);
  element.title = `Policy passed: 0 fixable vulnerabilities; ${total} known ${total === 1 ? "finding" : "findings"} without an available fix`;
}

function fillSeverityBreakdown(container, image) {
  const present = presentSeverities(image);
  container.replaceChildren();
  if (present.length === 0) {
    container.append(severityBadge("none", undefined, "0 FINDINGS"));
    return;
  }
  for (const { severity, count } of present) {
    container.append(severityBadge(severity, count));
  }
}

// Heuristic: FIPS builds are only distinguishable today by a "-fips" suffix
// on the version string. Should become a real catalog field later.
function isFipsVariant(version) {
  return /-fips$/i.test(version);
}

function tagBuildDate(tag) {
  const match = DATE_TAG.exec(tag);
  if (!match) return null;
  const [, stamp] = match;
  const date = new Date(
    Date.UTC(Number(stamp.slice(0, 4)), Number(stamp.slice(4, 6)) - 1, Number(stamp.slice(6, 8))),
  );
  return Number.isNaN(date.getTime()) ? null : date;
}

function buildDate(image) {
  let latest = null;
  for (const tag of image.tags) {
    const date = tagBuildDate(tag);
    if (date && (!latest || date > latest)) latest = date;
  }
  return latest;
}

function groupBuildDate(group) {
  let latest = null;
  for (const variant of group.variants) {
    const date = buildDate(variant);
    if (date && (!latest || date > latest)) latest = date;
  }
  return latest;
}

function relativeAge(date) {
  const days = Math.floor((Date.now() - date.getTime()) / 86400000);
  if (days <= 0) return "TODAY";
  if (days < 7) return `${days}D AGO`;
  const weeks = Math.floor(days / 7);
  if (weeks < 5) return `${weeks}W AGO`;
  const months = Math.floor(days / 30);
  if (months < 12) return `${months}MO AGO`;
  return `${Math.floor(days / 365)}Y AGO`;
}

function fillFreshness(element, date) {
  element.textContent = date ? relativeAge(date) : "NO DATE";
  if (date) {
    element.dateTime = date.toISOString();
    element.title = date.toISOString().slice(0, 10);
  } else {
    element.removeAttribute("datetime");
    element.title = "No date-stamped tag was published for this image";
  }
}

function slugify(value) {
  return value
    .toLowerCase()
    .replace(/[^a-z0-9.-]+/g, "-")
    .replace(/-{2,}/g, "-")
    .replace(/^-|-$/g, "");
}

// The stable, filter-proof id for a single catalog record. Name alone is not
// unique once a name has multiple published variants.
function imageSlug(image) {
  return `${image.name}-${slugify(image.version)}`;
}

function searchableText(image) {
  return [image.name, image.version, image.description, image.track, ...image.tags]
    .join(" ")
    .toLowerCase();
}

function compareVersionDesc(left, right) {
  return right.version.localeCompare(left.version, undefined, { numeric: true });
}

function groupImages(list) {
  const byName = new Map();
  for (const image of list) {
    if (!byName.has(image.name)) byName.set(image.name, []);
    byName.get(image.name).push(image);
  }
  return [...byName.values()].map((variants) => {
    const sorted = variants.slice().sort(compareVersionDesc);
    // The plain build is the one most people want, so a "-fips" variant should
    // not headline a group just because its version string sorts highest.
    const headline = sorted.find((image) => !isFipsVariant(image.version)) ?? sorted[0];
    return { name: sorted[0].name, variants: sorted, headline };
  });
}

function verificationRow(label, command) {
  const row = document.createElement("div");
  const name = document.createElement("span");
  const code = document.createElement("code");
  row.className = "verify-row";
  name.textContent = label;
  code.textContent = command;
  row.append(name, code);
  return row;
}

// Fills the description/tags/pull-command/verification block shared by a
// standalone row and each variant inside a grouped row.
function fillDescription(container, image) {
  container.querySelector(".description").textContent = image.description;
  fillSeverityBreakdown(container.querySelector(".severity-breakdown"), image);

  const repository = published(image.registry);
  const tags = container.querySelector(".tags");
  for (const tag of image.tags.slice(0, 5)) {
    const badge = document.createElement("button");
    badge.type = "button";
    badge.className = "tag-button";
    badge.textContent = tag;
    badge.dataset.copy = `docker pull ${repository}:${tag}`;
    badge.title = `Copy docker pull ${repository}:${tag}`;
    tags.append(badge);
  }

  container.querySelector(".pull-command").textContent = `docker pull ${published(image.reference)}`;

  const commands = container.querySelector(".verification-commands");
  for (const [label, command] of Object.entries(image.verification)) {
    commands.append(verificationRow(label.toUpperCase(), published(command)));
  }
}

function fillVariantHeading(container, image) {
  container.querySelector(".variant-version").textContent = image.version;
  container.querySelector(".fips-marker").hidden = !isFipsVariant(image.version);
  container.querySelector(".variant-digest").textContent = shortDigest(image.digest);
  fillFindings(container.querySelector(".variant-findings"), image);
  fillFreshness(container.querySelector(".variant-built"), buildDate(image));
}

function buildDetailBlock(image, { heading }) {
  const block = variantTemplate.content.firstElementChild.cloneNode(true);
  if (heading) {
    fillVariantHeading(block, image);
  } else {
    block.querySelector(".variant-heading").remove();
  }
  fillDescription(block, image);
  block.dataset.slug = imageSlug(image);
  return block;
}

function buildRow(group) {
  const headline = group.headline;
  const isGroup = group.variants.length > 1;
  const row = template.content.firstElementChild.cloneNode(true);
  row.dataset.track = headline.track;
  row.dataset.slug = imageSlug(headline);
  row.dataset.variantSlugs = group.variants.map(imageSlug).join(" ");

  row.querySelector(".name-text").textContent = group.name;
  const variantBadge = row.querySelector(".row-variants");
  variantBadge.hidden = !isGroup;
  if (isGroup) {
    variantBadge.textContent = `×${group.variants.length}`;
    variantBadge.title = `${group.variants.length} variants published under ${group.name}`;
  }

  row.querySelector(".row-track").textContent = headline.track.toUpperCase();
  row.querySelector(".version-text").textContent = headline.version;
  row.querySelector(".row-version .fips-marker").hidden = !isFipsVariant(headline.version);
  row.querySelector(".row-digest").textContent = shortDigest(headline.digest);
  fillFindings(row.querySelector(".row-findings"), headline);
  fillFreshness(row.querySelector(".row-freshness"), groupBuildDate(group));

  const detail = row.querySelector(".row-detail");
  if (isGroup) {
    detail.append(...group.variants.map((variant) => buildDetailBlock(variant, { heading: true })));
  } else {
    detail.append(buildDetailBlock(headline, { heading: false }));
  }

  row.querySelector(".copy-button").dataset.copy = `docker pull ${published(headline.reference)}`;

  row.addEventListener("toggle", () => {
    if (row.open) {
      openSlug = row.dataset.slug;
    } else if (openSlug === row.dataset.slug) {
      openSlug = "";
    }
    syncUrl();
  });

  return row;
}

function visibleGroups() {
  const query = search.value.trim().toLowerCase();
  const filtered = groups.filter(
    (group) =>
      (activeTrack === "all" || group.variants.some((variant) => variant.track === activeTrack)) &&
      (!query || group.variants.some((variant) => searchableText(variant).includes(query))),
  );
  return filtered.sort((left, right) => {
    if (sort.value === "newest") {
      return compareVersionDesc(left.variants[0], right.variants[0]);
    }
    if (sort.value === "recent") {
      const leftDate = groupBuildDate(left);
      const rightDate = groupBuildDate(right);
      if (leftDate && rightDate) return rightDate - leftDate;
      if (leftDate) return -1;
      if (rightDate) return 1;
      return left.name.localeCompare(right.name);
    }
    return left.name.localeCompare(right.name) || compareVersionDesc(left.variants[0], right.variants[0]);
  });
}

function findRowBySlug(slug) {
  if (!slug) return null;
  return (
    [...grid.children].find(
      (row) => row.dataset.slug === slug || (row.dataset.variantSlugs ?? "").split(" ").includes(slug),
    ) ?? null
  );
}

// Re-opens whichever row matches the tracked slug after a re-render. Stale
// or unknown slugs (from a hand-edited or outdated URL) are dropped quietly.
function restoreOpenRow() {
  if (!openSlug) return;
  const row = findRowBySlug(openSlug);
  if (!row) {
    openSlug = "";
    return;
  }
  row.open = true;
  if (firstRender) {
    const target = [...row.querySelectorAll("[data-slug]")].find((el) => el.dataset.slug === openSlug) ?? row;
    target.scrollIntoView({ block: "center" });
  }
}

function currentStateParams() {
  const params = new URLSearchParams();
  const query = search.value.trim();
  if (query) params.set("q", query);
  if (activeTrack !== "all") params.set("track", activeTrack);
  if (sort.value !== "name") params.set("sort", sort.value);
  if (openSlug) params.set("open", openSlug);
  return params;
}

function syncUrl() {
  const query = currentStateParams().toString();
  history.replaceState(null, "", `${location.pathname}${query ? `?${query}` : ""}${location.hash}`);
}

function applyTrack(track) {
  activeTrack = track;
  for (const button of filterButtons) {
    button.setAttribute("aria-pressed", String(button.dataset.track === track));
  }
}

function setTrack(track) {
  applyTrack(track);
  render();
}

// Parses ?q=&track=&sort=&open= before the first render so the initial view
// reflects the URL. Returns the requested open slug, if any.
function applyInitialUrlState() {
  const params = new URLSearchParams(location.search);
  const query = params.get("q");
  if (query) search.value = query;
  const track = params.get("track");
  if (track === "wolfi" || track === "patched") applyTrack(track);
  const sortValue = params.get("sort");
  if (sortValue === "newest" || sortValue === "recent") sort.value = sortValue;
  return params.get("open") ?? "";
}

function render() {
  const visible = visibleGroups();
  const fragment = document.createDocumentFragment();
  visible.forEach((group) => fragment.append(buildRow(group)));
  grid.replaceChildren(fragment);
  grid.setAttribute("aria-busy", "false");
  emptyState.hidden = visible.length !== 0;
  status.textContent = `${visible.length} OF ${groups.length} CATALOG ENTRIES`;
  restoreOpenRow();
  firstRender = false;
  syncUrl();
}

function updateSummary(catalog) {
  const wolfi = catalog.images.filter((image) => image.track === "wolfi").length;
  const patched = catalog.images.length - wolfi;
  setText("#metric-images", catalog.images.length);
  setText("#metric-wolfi", wolfi);
  setText("#metric-patched", patched);
  setText("#count-all", catalog.images.length);
  setText("#count-wolfi", wolfi);
  setText("#count-patched", patched);
  setText("#policy-sbom", catalog.policy.sbomFormat);

  const published = new Date(catalog.publishedAt);
  const publishedElement = document.querySelector("#published-at");
  publishedElement.dateTime = catalog.publishedAt;
  publishedElement.textContent = published.toISOString().slice(0, 10);
  const source = document.querySelector("#source-link");
  source.href = catalog.source.runUrl;
  source.textContent = catalog.source.commit.slice(0, 8).toUpperCase();
}

function catalogShape(value) {
  return (
    value &&
    value.schemaVersion === 2 &&
    Array.isArray(value.images) &&
    value.images.every(
      (image) =>
        typeof image.name === "string" &&
        typeof image.reference === "string" &&
        Array.isArray(image.tags) &&
        image.verification,
    )
  );
}

async function loadCatalog() {
  const response = await fetch("catalog.json", { headers: { Accept: "application/json" } });
  if (!response.ok) throw new Error(`catalog request failed: ${response.status}`);
  const catalog = await response.json();
  if (!catalogShape(catalog)) throw new Error("catalog schema is unsupported");
  images = catalog.images;
  groups = groupImages(images);
  updateSummary(catalog);
  openSlug = applyInitialUrlState();
  render();
}

function swapFeedback(button) {
  if (!window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
    button.animate(
      [
        { opacity: 0.3, filter: "blur(4px)", transform: "scale(0.96)" },
        { opacity: 1, filter: "blur(0)", transform: "scale(1)" },
      ],
      { duration: 200, easing: "ease-in-out" },
    );
  }
}

async function writeClipboard(text) {
  if (navigator.clipboard?.writeText) {
    await navigator.clipboard.writeText(text);
    return;
  }
  // The async clipboard needs a secure context, which plain-HTTP previews lack.
  const carrier = document.createElement("textarea");
  carrier.value = text;
  carrier.readOnly = true;
  // Offscreen rather than transparent: a zero-opacity field selects nothing.
  carrier.style.cssText = "position:fixed;left:-9999px;top:0;width:1px;height:1px";
  document.body.append(carrier);
  carrier.select();
  carrier.setSelectionRange(0, text.length);
  const copied = document.execCommand("copy");
  carrier.remove();
  if (!copied) throw new Error("clipboard unavailable");
}

async function copyCommand(button, { swapLabel = true } = {}) {
  // Tag chips keep their label so the row does not reflow on copy.
  if (!button.dataset.label) button.dataset.label = button.textContent;
  try {
    await writeClipboard(button.dataset.copy);
    if (swapLabel) button.textContent = "COPIED";
    button.dataset.state = "copied";
  } catch {
    if (swapLabel) button.textContent = "SELECT";
    button.dataset.state = "error";
  }
  swapFeedback(button);
  window.clearTimeout(Number(button.dataset.timer));
  button.dataset.timer = String(
    window.setTimeout(() => {
      button.textContent = button.dataset.label;
      delete button.dataset.state;
    }, 1800),
  );
}

for (const button of filterButtons) {
  button.addEventListener("click", () => setTrack(button.dataset.track));
}
search.addEventListener("input", render);
sort.addEventListener("change", render);
document.querySelector("#clear-filters").addEventListener("click", () => {
  search.value = "";
  setTrack("all");
  search.focus();
});
grid.addEventListener("click", (event) => {
  const tag = event.target.closest(".tag-button");
  if (tag) {
    copyCommand(tag, { swapLabel: false });
    return;
  }
  const button = event.target.closest(".copy-button");
  if (!button) return;
  // The button sits inside the row summary, which would otherwise toggle.
  event.preventDefault();
  copyCommand(button);
});
document.addEventListener("keydown", (event) => {
  if (event.key === "/" && document.activeElement !== search) {
    event.preventDefault();
    search.focus();
  }
  if (event.key === "Escape" && document.activeElement === search && search.value) {
    search.value = "";
    render();
  }
});

loadCatalog().catch(() => {
  grid.setAttribute("aria-busy", "false");
  status.textContent = "CATALOG UNAVAILABLE";
  errorState.hidden = false;
});
