// MeowBar — lock screen widget for Scriptable (free on the App Store).
// 1. Install Scriptable on your iPhone
// 2. New script → paste this file → name it "MeowBar"
// 3. Lock screen → customize → add widget → Scriptable → pick "MeowBar"
// Works on your home WiFi. Away from home? Use Tailscale to reach your Mac.

const ENDPOINT = "http://Clarks-MacBook-Air.local/MeowBar/mobile/usage.json";

const fam = config.widgetFamily || "";
const w = new ListWidget();
w.backgroundColor = new Color("#0a0a0a");

function left(win) {
  return win ? Math.max(0, 100 - Math.round(win.usedPercent)) : null;
}

function worst(p) {
  const v = [left(p.session), left(p.weekly)].filter((x) => x !== null);
  return v.length ? Math.min(...v) : null;
}

function label(p) {
  const s = left(p.session);
  const wk = left(p.weekly);
  if (s === null && wk === null)
    return p.name + "  " + (p.noteAccent === "unlimited" ? "unlimited" : (p.note || "—"));
  let t = p.name + "  " + (s === null ? "–" : s + "%");
  if (wk !== null) t += " · wk " + wk + "%";
  return t;
}

async function main() {
  let data;
  try {
    data = await new Request(ENDPOINT).loadJSON();
  } catch (e) {
    const t = w.addText("MeowBar offline");
    t.font = Font.systemFont(13);
    t.textColor = Color.white();
  }

  if (data) {
    if (fam === "accessoryCircular") {
      const worstPct = Math.min(...data.map(worst).filter((x) => x !== null));
      w.addSpacer();
      const stack = w.addStack();
      stack.addSpacer();
      const big = stack.addText(worstPct + "%");
      big.font = Font.boldSystemFont(22);
      big.textColor = worstPct <= 10 ? Color.red() : Color.white();
      stack.addSpacer();
      w.addSpacer();
      const sub = w.addText("left");
      sub.font = Font.systemFont(9);
      sub.textColor = Color.gray();
      sub.centerAlignText();
    } else if (fam === "accessoryInline") {
      const t = w.addText(data.map((p) => {
        const s = left(p.session);
        return p.name + " " + (s === null ? (worst(p) ?? "∞") + "%" : s + "%");
      }).join("  "));
      t.font = Font.systemFont(12);
    } else {
      // rectangular (lock screen) or small/medium home widget
      for (const p of data.slice(0, 3)) {
        const t = w.addText(label(p));
        t.font = Font.mediumSystemFont(13);
        const wp = worst(p);
        t.textColor = wp !== null && wp <= 10 ? Color.red() : Color.white();
        w.addSpacer(2);
      }
      const age = Math.round((Date.now() / 1000 - Math.max(...data.map((p) => p.fetchedAt || 0))) / 60);
      const f = w.addText(age <= 1 ? "just now" : age + "m ago");
      f.font = Font.systemFont(9);
      f.textColor = Color.gray();
    }
  }

  w.refreshAfterDate = new Date(Date.now() + 10 * 60 * 1000);
  Script.setWidget(w);
  Script.complete();
  if (config.runsInApp) {
    fam === "accessoryCircular" ? w.presentAccessoryCircular()
    : fam === "accessoryInline" ? w.presentAccessoryInline()
    : w.presentAccessoryRectangular();
  }
}

await main();
