const PALETTE = {
  teal: "#2E9C7E", amber: "#D98B3E", rust: "#C1543B", blue: "#4E8FBF",
  sage: "#A9B8AC", paper: "#F3EEE1", grid: "rgba(169,184,172,0.12)",
};

if (window.Chart) {
  Chart.defaults.color = "#A9B8AC";
  Chart.defaults.font.family = "'IBM Plex Mono', ui-monospace, monospace";
  Chart.defaults.font.size = 11;
  Chart.defaults.borderColor = PALETTE.grid;
}

function fmtMoney(v){
  if (Math.abs(v) >= 1e6) return (v/1e6).toFixed(1) + "M TND";
  if (Math.abs(v) >= 1e3) return (v/1e3).toFixed(0) + "k TND";
  return v.toFixed(0) + " TND";
}
function fmtInt(v){ return new Intl.NumberFormat("fr-FR").format(v); }
function fmtPct(v){ return v.toFixed(1) + "%"; }

// Vérification défensive : si Chart.js n'a pas pu se charger (CDN indisponible,
// bloqueur de script...), afficher un bandeau clair plutôt que des graphiques
// vides sans explication. Les KPI déjà rendus restent visibles.
function assertChartJsLoaded(){
  if (typeof Chart !== "undefined") return true;
  const contentEl = document.getElementById("content");
  if (contentEl && !document.getElementById("chartjs-warning")) {
    const banner = document.createElement("div");
    banner.id = "chartjs-warning";
    banner.style.cssText =
      "background:rgba(193,84,59,0.16); border:1px solid #C1543B; color:#F3EEE1; " +
      "font-family:'IBM Plex Mono',monospace; font-size:12.5px; padding:14px 18px; " +
      "border-radius:6px; margin-bottom:20px;";
    banner.textContent =
      "Chart.js n'a pas pu se charger (CDN indisponible ou bloquée) : les graphiques " +
      "ne peuvent pas s'afficher. Les indicateurs ci-dessus restent valides. Réessayez de recharger la page.";
    contentEl.prepend(banner);
  }
  return false;
}
