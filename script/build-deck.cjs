// GradientShield demo deck — generated against the current repo state.
const pptxgen = require("pptxgenjs");

const pres = new pptxgen();
pres.layout = "LAYOUT_WIDE"; // 13.3 x 7.5
pres.author = "GradientShield";
pres.title = "GradientShield";

// ---- palette: dark security surface, mint = protected, coral = penalised ----
const BG = "0F1922";
const CARD = "1B2A36";
const CARD2 = "213341";
const MINT = "06D6A0";
const CORAL = "FF6B5B";
const AMBER = "FFC15E";
const TEXT = "EAF2F6";
const MUTED = "8FA3B0";
const DIM = "5D717E";

const H = "Arial";
const B = "Calibri";
const MONO = "Courier New";

const W = 13.3;
const M = 0.7; // page margin

function bg(slide, color) {
  slide.background = { color: color || BG };
}

function title(slide, text, y) {
  slide.addText(text, {
    x: M, y: y === undefined ? 0.5 : y, w: W - M * 2, h: 0.75,
    fontSize: 34, bold: true, color: TEXT, fontFace: H,
    isTextBox: true, margin: 0,
  });
}

function kicker(slide, text, y) {
  slide.addText(text, {
    x: M, y: y === undefined ? 1.22 : y, w: W - M * 2, h: 0.35,
    fontSize: 13, color: MINT, fontFace: B, charSpacing: 1.6,
    isTextBox: true, margin: 0,
  });
}

function card(slide, x, y, w, h, fill) {
  slide.addShape(pres.ShapeType.roundRect, {
    x, y, w, h, rectRadius: 0.08,
    fill: { color: fill || CARD },
    line: { color: fill || CARD, width: 0 },
  });
}

function badge(slide, x, y, label, color) {
  slide.addShape(pres.ShapeType.ellipse, {
    x, y, w: 0.42, h: 0.42,
    fill: { color: color },
    line: { color: color, width: 0 },
  });
  slide.addText(label, {
    x, y, w: 0.42, h: 0.42,
    fontSize: 14, bold: true, color: BG, fontFace: H,
    align: "center", valign: "middle", isTextBox: true, margin: 0,
  });
}

// =====================================================================
// 1. Title
// =====================================================================
{
  const s = pres.addSlide();
  bg(s);

  s.addText("GradientShield", {
    x: M, y: 2.15, w: 9.5, h: 1.1,
    fontSize: 60, bold: true, color: TEXT, fontFace: H, isTextBox: true, margin: 0,
  });

  s.addText("MEV protection that prices the attacker, not the trade", {
    x: M, y: 3.3, w: 10.2, h: 0.55,
    fontSize: 22, color: MINT, fontFace: B, isTextBox: true, margin: 0,
  });

  s.addText(
    "A Uniswap v4 hook. Sandwich and JIT detection on the first trade, " +
    "progressive fees instead of blocked trades, and an EigenLayer-style BLS " +
    "operator quorum that turns observed attacks into on-chain reputation.",
    {
      x: M, y: 4.0, w: 8.6, h: 1.0,
      fontSize: 15, color: MUTED, fontFace: B, lineSpacing: 22, isTextBox: true, margin: 0,
    }
  );

  const stats = [
    ["247", "tests, 20 suites"],
    ["12.8 KB", "hook bytecode"],
    ["5.3x", "attacker cost"],
  ];
  stats.forEach(([big, small], i) => {
    const x = M + i * 2.5;
    s.addText(big, {
      x, y: 5.45, w: 2.3, h: 0.5,
      fontSize: 26, bold: true, color: AMBER, fontFace: H, isTextBox: true, margin: 0,
    });
    s.addText(small, {
      x, y: 5.95, w: 2.3, h: 0.3,
      fontSize: 12, color: DIM, fontFace: B, isTextBox: true, margin: 0,
    });
  });

  s.addText("Sivaji Alla", {
    x: M, y: 6.45, w: 1.9, h: 0.32,
    fontSize: 15, bold: true, color: TEXT, fontFace: H,
    valign: "middle", isTextBox: true, margin: 0,
  });
  s.addText("sivajialla01@gmail.com", {
    x: M + 2.0, y: 6.45, w: 4.5, h: 0.32,
    fontSize: 12, color: MUTED, fontFace: B,
    valign: "middle", isTextBox: true, margin: 0,
  });
  s.addText("Project HK-UHI10-1050", {
    x: M, y: 6.78, w: 6, h: 0.3,
    fontSize: 11, color: DIM, fontFace: B, isTextBox: true, margin: 0,
  });

  s.addNotes(
    "GradientShield is a Uniswap v4 hook that makes MEV extraction unprofitable. " +
    "The headline framing matters: we do not block trades and we do not claim to " +
    "give the victim their price back. We make the attacker pay, measurably, while " +
    "leaving honest traders exactly where an ordinary pool would leave them. " +
    "247 tests, and a live loop you can run on anvil."
  );
}

// =====================================================================
// 2. The problem
// =====================================================================
{
  const s = pres.addSlide();
  bg(s);
  kicker(s, "THE PROBLEM", 0.55);
  title(s, "A sandwich is three transactions in one block", 0.95);

  const steps = [
    ["1", "Bot front-runs", "Buys ahead of the victim, pushing the price up.", CORAL],
    ["2", "Victim swaps", "Executes at the worse price the bot just created.", AMBER],
    ["3", "Bot back-runs", "Sells into the move and books the spread.", CORAL],
  ];

  steps.forEach(([n, head, body, col], i) => {
    const x = M + i * 4.05;
    card(s, x, 2.15, 3.75, 1.95);
    badge(s, x + 0.3, 2.45, n, col);
    s.addText(head, {
      x: x + 0.3, y: 3.0, w: 3.15, h: 0.35,
      fontSize: 17, bold: true, color: TEXT, fontFace: H, isTextBox: true, margin: 0,
    });
    s.addText(body, {
      x: x + 0.3, y: 3.38, w: 3.15, h: 0.62,
      fontSize: 13, color: MUTED, fontFace: B, lineSpacing: 18, isTextBox: true, margin: 0,
    });
  });

  card(s, M, 4.45, W - M * 2, 1.65, CARD2);
  s.addText("Why existing defences miss it", {
    x: M + 0.35, y: 4.68, w: 5.5, h: 0.35,
    fontSize: 16, bold: true, color: MINT, fontFace: H, isTextBox: true, margin: 0,
  });
  s.addText(
    [
      { text: "Reputation systems are reactive — the first attack from a fresh address always lands.", options: { bullet: true, breakLine: true } },
      { text: "Hard caps that revert oversized trades break permissionlessness for everyone else.", options: { bullet: true, breakLine: true } },
      { text: "Uniswap v4 hands a hook the router address, not the trader — so everyone behind one router shares an identity.", options: { bullet: true } },
    ],
    {
      x: M + 0.35, y: 5.05, w: W - M * 2 - 0.7, h: 0.95,
      fontSize: 13, color: MUTED, fontFace: B, paraSpaceAfter: 5, isTextBox: true, margin: 0,
    }
  );

  s.addNotes(
    "Three transactions, one block. The bot buys ahead, the victim gets a worse " +
    "price, the bot sells into it. Three reasons existing defences miss: reputation " +
    "is reactive so the first attack always succeeds; hard caps that revert break " +
    "permissionlessness; and v4 hands the hook a router address rather than a person, " +
    "so everyone behind the Universal Router looks like the same trader."
  );
}

// =====================================================================
// 3. Original idea
// =====================================================================
{
  const s = pres.addSlide();
  bg(s);
  kicker(s, "ORIGINAL IDEA", 0.55);
  title(s, "Three things no other MEV hook does together", 0.95);

  const claims = [
    [
      "Protection before reputation exists",
      "Score the address, then act — so the first attack from a fresh wallet always lands.",
      "The volume guard prices the very first sandwich. No history, no oracle, no waiting.",
    ],
    [
      "Penalise without excluding",
      "Revert oversized trades, or gate the pool behind an allowlist.",
      "Fees escalate with the trader's own volume. Any address, any size, any time — priced.",
    ],
    [
      "Identity at the trader, not the router",
      "Key on the address v4 hands the hook, which is a router shared by thousands.",
      "Resolve the real trader, so one bot cannot tax everyone behind its router.",
    ],
  ];

  claims.forEach(([head, usual, ours], i) => {
    const y = 1.95 + i * 1.62;
    card(s, M, y, W - M * 2, 1.42);
    badge(s, M + 0.28, y + 0.2, String(i + 1), MINT);

    s.addText(head, {
      x: M + 0.85, y: y + 0.18, w: 10.8, h: 0.32,
      fontSize: 17, bold: true, color: TEXT, fontFace: H, isTextBox: true, margin: 0,
    });

    s.addText("Typical hook", {
      x: M + 0.85, y: y + 0.58, w: 1.5, h: 0.26,
      fontSize: 11, color: DIM, fontFace: B, isTextBox: true, margin: 0,
    });
    s.addText(usual, {
      x: M + 2.4, y: y + 0.56, w: 4.0, h: 0.7,
      fontSize: 12, color: MUTED, fontFace: B, lineSpacing: 15, isTextBox: true, margin: 0,
    });

    s.addText("GradientShield", {
      x: M + 6.7, y: y + 0.58, w: 1.7, h: 0.26,
      fontSize: 11, bold: true, color: MINT, fontFace: B, isTextBox: true, margin: 0,
    });
    s.addText(ours, {
      x: M + 8.45, y: y + 0.56, w: 3.2, h: 0.7,
      fontSize: 12, color: TEXT, fontFace: B, lineSpacing: 15, isTextBox: true, margin: 0,
    });
  });

  s.addNotes(
    "If you take one slide away, take this one. Three things that are each " +
    "individually unusual and together are the idea. One: protection that works " +
    "before any reputation exists, which is what closes the cold-start hole every " +
    "reputation system has. Two: we penalise without ever excluding — no trade is " +
    "refused for its size, the fee just climbs. Three: identity resolved at the " +
    "trader rather than the router, which is the part most v4 hooks get wrong " +
    "without noticing."
  );
}

// =====================================================================
// 4. Five defense layers
// =====================================================================
{
  const s = pres.addSlide();
  bg(s);
  kicker(s, "ARCHITECTURE", 0.55);
  title(s, "Five layers, three of them on the first trade", 0.95);

  const layers = [
    ["1", "Trader volume fees", "First trade", "Per-trader volume per block. Past 5 ETH the fee steps 1.50% → 3.00% → 5.00%. No reverts.", MINT],
    ["2", "Pool impact guard", "First trade", "Pool-wide volume past 10 ETH in a block adds a 1.50% penalty.", MINT],
    ["3", "Sandwich / JIT detection", "Same block", "Block-scoped on-chain state spots buy→victim→sell and add→swap→remove.", MINT],
    ["4", "Continuous fee curve", "Every swap", "Score 0-100 maps onto 0.30% → 1.50%. Score 80+ is rejected outright.", AMBER],
    ["5", "AVS scoring quorum", "Async", "BLS operators read the hook's events and write a verified score on-chain.", AMBER],
  ];

  layers.forEach(([n, head, when, body, col], i) => {
    const y = 2.05 + i * 0.92;
    card(s, M, y, W - M * 2, 0.8);
    badge(s, M + 0.25, y + 0.19, n, col);
    s.addText(head, {
      x: M + 0.85, y: y + 0.12, w: 3.0, h: 0.3,
      fontSize: 15, bold: true, color: TEXT, fontFace: H, isTextBox: true, margin: 0,
    });
    s.addText(when, {
      x: M + 0.85, y: y + 0.44, w: 3.0, h: 0.25,
      fontSize: 11, color: col, fontFace: B, isTextBox: true, margin: 0,
    });
    s.addText(body, {
      x: M + 4.0, y: y + 0.2, w: W - M * 2 - 4.35, h: 0.55,
      fontSize: 13, color: MUTED, fontFace: B, isTextBox: true, margin: 0,
    });
  });

  s.addText("Layers 1-3 need no history — they act on an address's very first trade.", {
    x: M, y: 6.72, w: W - M * 2, h: 0.3,
    fontSize: 13, italic: true, color: MINT, fontFace: B, isTextBox: true, margin: 0,
  });

  s.addNotes(
    "Five layers. The important structural point is the split: layers one to three " +
    "act on the first ever trade with no reputation lookup, which is what closes the " +
    "cold-start hole. Layers four and five build the long memory so repeat offenders " +
    "escalate. Note layer one says no reverts — that was a deliberate change, covered next."
  );
}

// =====================================================================
// 5. Permissionless by design
// =====================================================================
{
  const s = pres.addSlide();
  bg(s);
  kicker(s, "DESIGN DECISION", 0.55);
  title(s, "Progressive fees, never a blocked trade", 0.95);

  card(s, M, 2.0, 5.6, 2.0, CARD2);
  s.addText("Rejected: a hard cap", {
    x: M + 0.35, y: 2.25, w: 4.9, h: 0.35,
    fontSize: 17, bold: true, color: CORAL, fontFace: H, isTextBox: true, margin: 0,
  });
  s.addText(
    "Reverting any swap above 5 ETH stops the sandwich — and also stops every " +
    "legitimate large trade. A pool anyone can be refused from is not permissionless.",
    {
      x: M + 0.35, y: 2.65, w: 4.9, h: 1.1,
      fontSize: 13, color: MUTED, fontFace: B, lineSpacing: 19, isTextBox: true, margin: 0,
    }
  );

  card(s, M + 6.0, 2.0, 5.6, 2.0);
  s.addText("Shipped: escalating fees", {
    x: M + 6.35, y: 2.25, w: 4.9, h: 0.35,
    fontSize: 17, bold: true, color: MINT, fontFace: H, isTextBox: true, margin: 0,
  });
  s.addText(
    "Any address can trade any size at any time. The fee climbs with how much " +
    "volume that trader pushes through one pool in one block.",
    {
      x: M + 6.35, y: 2.65, w: 4.9, h: 1.1,
      fontSize: 13, color: MUTED, fontFace: B, lineSpacing: 19, isTextBox: true, margin: 0,
    }
  );

  const tiers = [
    ["0 - 5 ETH", "0.30%", "base", DIM],
    ["5 - 10 ETH", "1.50%", "tier 1", AMBER],
    ["10 - 20 ETH", "3.00%", "tier 2", AMBER],
    ["20+ ETH", "5.00%", "tier 3", CORAL],
  ];
  tiers.forEach(([range, fee, tier, col], i) => {
    const x = M + i * 2.98;
    card(s, x, 4.3, 2.7, 1.55);
    s.addText(fee, {
      x: x + 0.25, y: 4.5, w: 2.2, h: 0.5,
      fontSize: 27, bold: true, color: col, fontFace: H, isTextBox: true, margin: 0,
    });
    s.addText(range, {
      x: x + 0.25, y: 5.02, w: 2.2, h: 0.3,
      fontSize: 13, color: TEXT, fontFace: B, isTextBox: true, margin: 0,
    });
    s.addText(tier, {
      x: x + 0.25, y: 5.32, w: 2.2, h: 0.28,
      fontSize: 11, color: DIM, fontFace: B, isTextBox: true, margin: 0,
    });
  });

  s.addText(
    "Volume is counted per trader, per pool, per block — and it resets every block.",
    {
      x: M, y: 6.2, w: W - M * 2, h: 0.3,
      fontSize: 13, italic: true, color: MINT, fontFace: B, isTextBox: true, margin: 0,
    }
  );

  s.addNotes(
    "This is the design decision I would lead with if asked what changed. The first " +
    "version reverted trades over 5 ETH. That kills the sandwich but it also refuses " +
    "honest large trades, and a pool you can be refused from is not permissionless. " +
    "So instead the fee escalates with the trader's own volume in that block. Anyone " +
    "can trade any amount at any time — it just gets progressively more expensive to " +
    "do the thing only an attacker needs to do."
  );
}

// =====================================================================
// 6. Trader identity
// =====================================================================
{
  const s = pres.addSlide();
  bg(s);
  kicker(s, "THE HARD PART", 0.55);
  title(s, "v4 gives the hook a router, not a person", 0.95);

  s.addText(
    "beforeSwap(address sender, ...)  // sender is whoever called poolManager.swap()",
    {
      x: M, y: 1.95, w: W - M * 2, h: 0.42,
      fontSize: 14, color: AMBER, fontFace: MONO, isTextBox: true, margin: 0,
    }
  );

  card(s, M, 2.55, 5.6, 1.9, CARD2);
  s.addText("Scoring the router breaks two ways", {
    x: M + 0.35, y: 2.78, w: 4.9, h: 0.35,
    fontSize: 16, bold: true, color: CORAL, fontFace: H, isTextBox: true, margin: 0,
  });
  s.addText(
    [
      { text: "An honest user inherits a bot's volume and pays its penalty.", options: { bullet: true, breakLine: true } },
      { text: "The router itself accrues score until it crosses 80 — bricking the pool for everyone behind it.", options: { bullet: true } },
    ],
    {
      x: M + 0.35, y: 3.18, w: 4.9, h: 1.05,
      fontSize: 13, color: MUTED, fontFace: B, paraSpaceAfter: 5, isTextBox: true, margin: 0,
    }
  );

  card(s, M + 6.0, 2.55, 5.6, 1.9);
  s.addText("How the hook resolves it", {
    x: M + 6.35, y: 2.78, w: 4.9, h: 0.35,
    fontSize: 16, bold: true, color: MINT, fontFace: H, isTextBox: true, margin: 0,
  });
  s.addText(
    [
      { text: "getMsgSender() on an allow-listed router", options: { bullet: true, breakLine: true } },
      { text: "originator the same router declared in hookData", options: { bullet: true, breakLine: true } },
      { text: "tx.origin — the EOA that signed", options: { bullet: true } },
    ],
    {
      x: M + 6.35, y: 3.18, w: 4.9, h: 1.05,
      fontSize: 13, color: MUTED, fontFace: B, paraSpaceAfter: 4, isTextBox: true, margin: 0,
    }
  );

  card(s, M, 4.75, W - M * 2, 1.6, CARD2);
  s.addText("The allow-list is load-bearing", {
    x: M + 0.35, y: 4.97, w: 6, h: 0.32,
    fontSize: 15, bold: true, color: AMBER, fontFace: H, isTextBox: true, margin: 0,
  });
  s.addText(
    "Anyone can call the PoolManager directly, which makes their contract the sender. " +
    "Asking an unvetted contract who it represents lets it name any address — laundering " +
    "its own reputation or framing an innocent one. So the getter is only ever called on " +
    "a router the owner has vetted, over STATICCALL, wrapped in try/catch.",
    {
      x: M + 0.35, y: 5.32, w: W - M * 2 - 0.7, h: 0.9,
      fontSize: 13, color: MUTED, fontFace: B, lineSpacing: 18, isTextBox: true, margin: 0,
    }
  );

  s.addText("21 tests in TraderIdentity.t.sol, including the spoofing attack itself.", {
    x: M, y: 6.55, w: W - M * 2, h: 0.3,
    fontSize: 12, italic: true, color: DIM, fontFace: B, isTextBox: true, margin: 0,
  });

  s.addNotes(
    "This is the question a Uniswap-savvy judge asks. In v4 the sender passed to the " +
    "hook is whoever called poolManager.swap — a router. If you score that, everyone " +
    "behind the Universal Router shares one reputation: an honest user inherits a bot's " +
    "volume, and eventually the router crosses the reject threshold and the pool is " +
    "bricked for everyone. We resolve the real trader, and the allow-list is the " +
    "security-critical piece: never ask an unvetted contract who it represents."
  );
}

// =====================================================================
// 7. Measured effect (the money slide)
// =====================================================================
{
  const s = pres.addSlide();
  bg(s);
  kicker(s, "MEASURED, NOT CLAIMED", 0.55);
  title(s, "Attacker pays 5.3x. Victim pays nothing extra.", 0.95);

  s.addText(
    "Identical sandwich, two identical pools — one plain, one guarded. " +
    "Front-run 4 ETH, victim 3 ETH, back-run 4 ETH.",
    {
      x: M, y: 1.85, w: W - M * 2, h: 0.35,
      fontSize: 14, color: MUTED, fontFace: B, isTextBox: true, margin: 0,
    }
  );

  s.addChart(
    pres.ChartType.bar,
    [{ name: "Attacker's loss (ETH)", labels: ["Plain pool", "GradientShield"], values: [0.0112, 0.0592] }],
    {
      x: M, y: 2.4, w: 6.0, h: 3.1,
      barDir: "col",
      chartColors: [DIM, CORAL],
      varyColors: true,
      showTitle: true,
      title: "Attacker's loss (ETH)",
      titleColor: TEXT,
      titleFontSize: 14,
      titleFontFace: H,
      showValue: true,
      dataLabelPosition: "outEnd",
      dataLabelColor: TEXT,
      dataLabelFontSize: 12,
      dataLabelFormatCode: "0.0000",
      showLegend: false,
      catAxisLabelColor: MUTED,
      catAxisLabelFontSize: 12,
      // The value axis is hidden: every bar already carries its exact value as
      // a data label, so the axis only duplicated it — and its labels were
      // indenting the plot area, leaving the bars visibly inset from the
      // slide title above them.
      valAxisHidden: true,
      valGridLine: { style: "none" },
      catGridLine: { style: "none" },
      plotArea: { fill: { color: BG } },
      chartArea: { fill: { color: BG } },
    }
  );

  const rows = [
    ["Victim receives", "2.990344077", "2.990344077", MINT],
    ["Victim's fee", "0.30%", "0.30%", MINT],
    ["Victim's loss to the attack", "0.000477", "0.000477", MUTED],
    ["Attacker's net P&L", "-0.011205", "-0.059211", CORAL],
  ];

  card(s, M + 6.4, 2.4, 5.2, 3.1);
  s.addText("Plain", {
    x: M + 9.05, y: 2.6, w: 1.15, h: 0.28,
    fontSize: 11, bold: true, color: DIM, fontFace: H, align: "right", isTextBox: true, margin: 0,
  });
  s.addText("Shielded", {
    x: M + 10.2, y: 2.6, w: 1.2, h: 0.28,
    fontSize: 11, bold: true, color: MINT, fontFace: H, align: "right", isTextBox: true, margin: 0,
  });

  rows.forEach(([label, a, b, col], i) => {
    const y = 2.98 + i * 0.58;
    s.addText(label, {
      x: M + 6.65, y, w: 2.5, h: 0.4,
      fontSize: 12, color: TEXT, fontFace: B, valign: "middle", isTextBox: true, margin: 0,
    });
    s.addText(a, {
      x: M + 9.05, y, w: 1.15, h: 0.4,
      fontSize: 12, color: MUTED, fontFace: MONO, align: "right", valign: "middle", isTextBox: true, margin: 0,
    });
    s.addText(b, {
      x: M + 10.2, y, w: 1.2, h: 0.4,
      fontSize: 12, bold: true, color: col, fontFace: MONO, align: "right", valign: "middle", isTextBox: true, margin: 0,
    });
  });

  s.addText(
    "Extra cost imposed on the attacker: 0.048 ETH — exactly the fee delta on its back-run. " +
    "Change in what the victim received: zero.",
    {
      x: M, y: 5.75, w: W - M * 2, h: 0.6,
      fontSize: 14, color: MINT, fontFace: B, lineSpacing: 20, isTextBox: true, margin: 0,
    }
  );

  s.addText("make demo-economics", {
    x: M, y: 6.5, w: 5, h: 0.32,
    fontSize: 13, color: AMBER, fontFace: MONO, isTextBox: true, margin: 0,
  });

  s.addNotes(
    "This is the slide to spend time on. We ran the same sandwich against two identical " +
    "pools — same liquidity, same sizes — and the only difference is the guard. The " +
    "attacker's loss goes from 0.0112 to 0.0592 ETH, so 5.3x, and the extra 0.048 is " +
    "exactly the fee delta on its back-run. The right-hand column is the part people " +
    "miss: the victim's execution is identical to the digit and they still pay base fee. " +
    "The guard costs innocent flow nothing."
  );
}

// =====================================================================
// 8. Honest limits
// =====================================================================
{
  const s = pres.addSlide();
  bg(s);
  kicker(s, "WHAT IT DOES NOT DO", 0.55);
  title(s, "A deterrent, not a shield", 0.95);

  card(s, M, 1.95, W - M * 2, 1.5, CARD2);
  s.addText("The victim is still sandwiched", {
    x: M + 0.35, y: 2.18, w: 6, h: 0.35,
    fontSize: 17, bold: true, color: CORAL, fontFace: H, isTextBox: true, margin: 0,
  });
  s.addText(
    "They lose the same 0.000477 ETH in both pools. The front-run lands before the " +
    "victim executes, so the price has already moved — a fee charged on the back-run " +
    "afterwards cannot undo that, and none of it is routed to the victim.",
    {
      x: M + 0.35, y: 2.56, w: W - M * 2 - 0.7, h: 0.8,
      fontSize: 13, color: MUTED, fontFace: B, lineSpacing: 18, isTextBox: true, margin: 0,
    }
  );

  const limits = [
    ["Pool guard hits bystanders", "The pool-level guard is pool-wide. Past 10 ETH in a block, a clean trader pays 1.50% too."],
    ["Cross-block sandwiches", "State resets each block, so a buy in block N and a sell in N+1 is not caught on-chain."],
    ["ERC-4337 behind an unvetted router", "tx.origin is the bundler, so those users share an identity until the router is allow-listed."],
    ["Fresh-wallet evasion", "A new address dodges reputation — but still pays the first-trade volume fee on every attempt."],
  ];

  limits.forEach(([head, body], i) => {
    const x = M + (i % 2) * 6.0;
    const y = 3.65 + Math.floor(i / 2) * 1.4;
    card(s, x, y, 5.6, 1.2);
    s.addText(head, {
      x: x + 0.3, y: y + 0.16, w: 5.0, h: 0.3,
      fontSize: 14, bold: true, color: AMBER, fontFace: H, isTextBox: true, margin: 0,
    });
    s.addText(body, {
      x: x + 0.3, y: y + 0.48, w: 5.0, h: 0.62,
      fontSize: 12, color: MUTED, fontFace: B, lineSpacing: 16, isTextBox: true, margin: 0,
    });
  });

  s.addText("Each of these is asserted by a passing test rather than left unsaid.", {
    x: M, y: 6.6, w: W - M * 2, h: 0.3,
    fontSize: 12, italic: true, color: MINT, fontFace: B, isTextBox: true, margin: 0,
  });

  s.addNotes(
    "I would rather say this than be caught on it. The guard does not give the victim " +
    "their price back — the front-run has already moved the market by the time they " +
    "execute. What it does is destroy the strategy's economics so the next victim never " +
    "gets hit, and route what is extracted to LPs, since the escalated fee is an LP fee. " +
    "Every limitation on this slide has a test asserting it, including the pool guard " +
    "charging a clean bystander."
  );
}

// =====================================================================
// 9. The AVS
// =====================================================================
{
  const s = pres.addSlide();
  bg(s);
  kicker(s, "THE AVS", 0.55);
  title(s, "Real BLS quorum, not a stub", 0.95);

  const flow = [
    ["Hook", "Detects the pattern and creates a scoring task on-chain.", MINT],
    ["Operators", "Independently replay the hook's events and compute a score.", MINT],
    ["Aggregator", "Sums the G1 signatures and the G2 keys, submits once.", AMBER],
    ["Chain", "Pairing precompile verifies; the oracle score is written.", CORAL],
  ];

  flow.forEach(([head, body, col], i) => {
    const x = M + i * 3.03;
    card(s, x, 1.95, 2.8, 1.75);
    s.addText(head, {
      x: x + 0.25, y: 2.15, w: 2.3, h: 0.32,
      fontSize: 16, bold: true, color: col, fontFace: H, isTextBox: true, margin: 0,
    });
    s.addText(body, {
      x: x + 0.25, y: 2.5, w: 2.3, h: 1.05,
      fontSize: 12, color: MUTED, fontFace: B, lineSpacing: 17, isTextBox: true, margin: 0,
    });
    if (i < 3) {
      s.addText("→", {
        x: x + 2.82, y: 2.6, w: 0.24, h: 0.4,
        fontSize: 18, color: DIM, fontFace: H, align: "center", isTextBox: true, margin: 0,
      });
    }
  });

  card(s, M, 3.95, 6.2, 2.35, CARD2);
  s.addText("The verification is genuine", {
    x: M + 0.35, y: 4.18, w: 5.5, h: 0.32,
    fontSize: 16, bold: true, color: TEXT, fontFace: H, isTextBox: true, margin: 0,
  });
  s.addText("e(σ + γ·apkG1, −g2) · e(H(m) + γ·g1, apkG2) == 1", {
    x: M + 0.35, y: 4.55, w: 5.5, h: 0.35,
    fontSize: 12, color: AMBER, fontFace: MONO, isTextBox: true, margin: 0,
  });
  s.addText(
    [
      { text: "BN254 keys in G2, signatures in G1", options: { bullet: true, breakLine: true } },
      { text: "Signer keys summed on-chain from the registry", options: { bullet: true, breakLine: true } },
      { text: "Forged signatures and duplicate signers rejected", options: { bullet: true } },
    ],
    {
      x: M + 0.35, y: 5.0, w: 5.5, h: 1.1,
      fontSize: 12, color: MUTED, fontFace: B, paraSpaceAfter: 4, isTextBox: true, margin: 0,
    }
  );

  card(s, M + 6.6, 3.95, 5.0, 2.35);
  s.addText("Scoring weights", {
    x: M + 6.95, y: 4.18, w: 4.3, h: 0.32,
    fontSize: 16, bold: true, color: TEXT, fontFace: H, isTextBox: true, margin: 0,
  });
  const weights = [["Sandwich detected", "+35"], ["Volume breach", "+30"], ["JIT detected", "+25"], ["Round-trip pattern", "+20"]];
  weights.forEach(([k, v], i) => {
    const y = 4.62 + i * 0.4;
    s.addText(k, {
      x: M + 6.95, y, w: 3.2, h: 0.32,
      fontSize: 12, color: MUTED, fontFace: B, valign: "middle", isTextBox: true, margin: 0,
    });
    s.addText(v, {
      x: M + 10.2, y, w: 1.0, h: 0.32,
      fontSize: 12, bold: true, color: AMBER, fontFace: MONO, align: "right", valign: "middle", isTextBox: true, margin: 0,
    });
  });

  s.addText("Scores decay 5 points a day, so a reformed address heals back to clean.", {
    x: M, y: 6.55, w: W - M * 2, h: 0.3,
    fontSize: 12, italic: true, color: MINT, fontFace: B, isTextBox: true, margin: 0,
  });

  s.addNotes(
    "The AVS is not mocked. Operators sign a BN254 BLS signature, the aggregator sums " +
    "them, and the EVM pairing precompile verifies the aggregate against the signer set " +
    "the contract derives from its own registry. The gamma term proves in one pairing " +
    "both that the signature is valid and that the G1 and G2 aggregate keys match — the " +
    "same construction EigenLayer's BLSSignatureChecker uses. Forged signatures, wrong " +
    "aggregate keys and duplicate signers are all rejected by tests."
  );
}

// =====================================================================
// 10. Functionality / verification
// =====================================================================
{
  const s = pres.addSlide();
  bg(s);
  kicker(s, "FUNCTIONALITY", 0.55);
  title(s, "247 tests, and a loop that closes on a real chain", 0.95);

  // What the tests actually prove — not just a count.
  card(s, M, 1.9, 6.2, 3.6);
  s.addText("What the suite proves", {
    x: M + 0.3, y: 2.1, w: 5.5, h: 0.3,
    fontSize: 15, bold: true, color: TEXT, fontFace: H, isTextBox: true, margin: 0,
  });

  const suites = [
    ["Trader vs router identity", "21"],
    ["BLS quorum, real signatures", "13"],
    ["Volume tiers + pool guard", "26"],
    ["Storage survives across txs", "5"],
    ["A/B against a plain pool", "4"],
    ["Edge cases, access, coverage", "178"],
  ];
  suites.forEach(([k, v], i) => {
    const y = 2.5 + i * 0.44;
    s.addText(k, {
      x: M + 0.3, y, w: 4.5, h: 0.36,
      fontSize: 12, color: MUTED, fontFace: B, valign: "middle", isTextBox: true, margin: 0,
    });
    s.addText(v, {
      x: M + 4.9, y, w: 0.9, h: 0.36,
      fontSize: 13, bold: true, color: AMBER, fontFace: MONO,
      align: "right", valign: "middle", isTextBox: true, margin: 0,
    });
  });

  s.addText("forge test  —  no setup, ~1 second", {
    x: M + 0.3, y: 5.12, w: 5.5, h: 0.3,
    fontSize: 12, color: MINT, fontFace: MONO, isTextBox: true, margin: 0,
  });

  // The live run, as evidence rather than a performance.
  card(s, M + 6.6, 1.9, 5.0, 3.6, CARD2);
  s.addText("And it runs end to end", {
    x: M + 6.9, y: 2.1, w: 4.4, h: 0.3,
    fontSize: 15, bold: true, color: TEXT, fontFace: H, isTextBox: true, margin: 0,
  });
  s.addText("Sandwich as 3 separate txs, one block:", {
    x: M + 6.9, y: 2.45, w: 4.4, h: 0.3,
    fontSize: 11, color: MUTED, fontFace: B, isTextBox: true, margin: 0,
  });
  s.addText(
    "bot     buy   4.0 ->  3000 pips\n" +
    "victim  buy   1.0 ->  3000 pips\n" +
    "bot     sell  4.0 -> 15000 pips\n\n" +
    "Flagged: bot\n" +
    "Router score: 0\n" +
    "3/3 operators signed\n" +
    "BLS pairing verified on-chain",
    {
      x: M + 6.9, y: 2.8, w: 4.4, h: 2.1,
      fontSize: 11, color: MINT, fontFace: MONO, lineSpacing: 15, isTextBox: true, margin: 0,
    }
  );
  s.addText("Bot and victim are separate EOAs on one router.", {
    x: M + 6.9, y: 5.0, w: 4.4, h: 0.42,
    fontSize: 11, color: DIM, fontFace: B, lineSpacing: 14, isTextBox: true, margin: 0,
  });

  s.addText(
    "Judges can reproduce every number here: clone, forge test, then four commands for the live loop.",
    {
      x: M, y: 5.75, w: W - M * 2, h: 0.35,
      fontSize: 13, italic: true, color: MINT, fontFace: B, isTextBox: true, margin: 0,
    }
  );

  s.addNotes(
    "The submission includes test cases rather than a frontend, so this is the " +
    "evidence slide. The left column is what the suite actually proves, broken out " +
    "by claim rather than a bare count — identity resolution, real BLS signatures, " +
    "the volume tiers, and the regression guard that catches detection state not " +
    "surviving across transactions. The right is a real run: three separate " +
    "transactions mined into one block, bot penalised, victim untouched, router " +
    "score zero, quorum signed. Every number on this deck is reproducible from a " +
    "clean clone."
  );
}

// =====================================================================
// 11. Submission
// =====================================================================
{
  const s = pres.addSlide();
  bg(s);

  s.addText("GradientShield", {
    x: M, y: 0.6, w: 9.5, h: 0.8,
    fontSize: 40, bold: true, color: TEXT, fontFace: H, isTextBox: true, margin: 0,
  });
  s.addText("Sivaji Alla  ·  Project HK-UHI10-1050", {
    x: M, y: 1.42, w: 8, h: 0.35,
    fontSize: 14, color: MINT, fontFace: B, isTextBox: true, margin: 0,
  });

  // Repository — the thing a judge acts on first.
  card(s, M, 2.0, W - M * 2, 1.0, CARD2);
  s.addText("github.com/sivajialla/gradient-shield", {
    x: M + 0.35, y: 2.28, w: 8.5, h: 0.45,
    fontSize: 20, bold: true, color: MINT, fontFace: MONO, isTextBox: true, margin: 0,
  });
  s.addText("forge test  ·  247 passing", {
    x: M + 8.3, y: 2.34, w: 3.3, h: 0.35,
    fontSize: 12, color: DIM, fontFace: B, align: "right", isTextBox: true, margin: 0,
  });

  // Judging criteria, answered.
  card(s, M, 3.2, 6.2, 2.55);
  s.addText("Judged on", {
    x: M + 0.3, y: 3.4, w: 5.5, h: 0.3,
    fontSize: 14, bold: true, color: TEXT, fontFace: H, isTextBox: true, margin: 0,
  });
  const crit = [
    ["Original idea", "First-trade protection, no history"],
    ["Unique execution", "Trader identity + real BLS quorum"],
    ["Impact", "Attacker pays 5.3x, victim untouched"],
    ["Functionality", "247 tests, live loop on anvil"],
  ];
  crit.forEach(([k, v], i) => {
    const y = 3.78 + i * 0.47;
    s.addText(k, {
      x: M + 0.3, y, w: 1.85, h: 0.4,
      fontSize: 12, bold: true, color: MINT, fontFace: B, valign: "middle", isTextBox: true, margin: 0,
    });
    s.addText(v, {
      x: M + 2.25, y, w: 3.6, h: 0.4,
      fontSize: 11, color: MUTED, fontFace: B, valign: "middle", isTextBox: true, margin: 0,
    });
  });

  // Theme fit — both halves.
  card(s, M + 6.6, 3.2, 5.0, 2.55, CARD2);
  s.addText("Theme", {
    x: M + 6.9, y: 3.4, w: 4.4, h: 0.3,
    fontSize: 14, bold: true, color: TEXT, fontFace: H, isTextBox: true, margin: 0,
  });
  s.addText("MEV protection", {
    x: M + 6.9, y: 3.8, w: 4.4, h: 0.28,
    fontSize: 13, bold: true, color: MINT, fontFace: H, isTextBox: true, margin: 0,
  });
  s.addText("Sandwich and JIT priced out on the first trade.", {
    x: M + 6.9, y: 4.08, w: 4.4, h: 0.5,
    fontSize: 11, color: MUTED, fontFace: B, lineSpacing: 15, isTextBox: true, margin: 0,
  });
  s.addText("Sustainable liquidity", {
    x: M + 6.9, y: 4.68, w: 4.4, h: 0.28,
    fontSize: 13, bold: true, color: MINT, fontFace: H, isTextBox: true, margin: 0,
  });
  s.addText("The penalty is an LP fee — extraction becomes LP yield.", {
    x: M + 6.9, y: 4.96, w: 4.4, h: 0.55,
    fontSize: 11, color: MUTED, fontFace: B, lineSpacing: 15, isTextBox: true, margin: 0,
  });

  // Submission artifacts.
  card(s, M, 5.95, W - M * 2, 0.85);
  const arts = [
    ["GitHub repo", "public, MIT"],
    ["Demo video", "linked in form"],
    ["Test cases", "247, in place of a frontend"],
  ];
  arts.forEach(([k, v], i) => {
    const x = M + 0.35 + i * 3.95;
    s.addText(k, {
      x, y: 6.13, w: 3.7, h: 0.28,
      fontSize: 12, bold: true, color: AMBER, fontFace: H, isTextBox: true, margin: 0,
    });
    s.addText(v, {
      x, y: 6.4, w: 3.7, h: 0.28,
      fontSize: 11, color: MUTED, fontFace: B, isTextBox: true, margin: 0,
    });
  });

  s.addNotes(
    "Closing slide, laid out against the judging criteria so nothing has to be " +
    "inferred. Original idea, unique execution, impact and functionality each get " +
    "a line. Both halves of the theme are covered — MEV protection is the obvious " +
    "one, sustainable liquidity because the escalated fee is an LP fee, so what the " +
    "attacker extracts is redirected into yield for the liquidity providers it was " +
    "preying on. Submission artifacts bottom row: repo, video, and test cases " +
    "rather than a frontend."
  );
}

pres.writeFile({ fileName: "GradientShield-Demo.pptx" }).then(() => console.log("written"));
