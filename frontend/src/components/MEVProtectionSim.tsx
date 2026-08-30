import { useState, useEffect, useRef } from 'react';
import './MEVProtectionSim.css';

interface TimelineEvent {
  label: string;
  detail: string;
  type: 'bot' | 'victim' | 'detection' | 'score' | 'reject' | 'lp';
}

const UNPROTECTED_TIMELINE: TimelineEvent[] = [
  { label: 'Bot Front-runs', detail: 'Bot buys 50 ETH → pushes price up 0.8%', type: 'bot' },
  { label: 'Victim Swaps', detail: 'User buys 2 ETH at inflated price (+0.8%)', type: 'victim' },
  { label: 'Bot Back-runs', detail: 'Bot sells 50 ETH at higher price', type: 'bot' },
  { label: 'Bot Profit', detail: 'Bot extracts ~0.4 ETH ($980) from victim + LP', type: 'bot' },
  { label: 'LP Impact', detail: 'LP suffers impermanent loss from price manipulation', type: 'lp' },
];

const PROTECTED_TIMELINE: TimelineEvent[] = [
  { label: 'Bot Front-runs', detail: 'Bot buys 50 ETH → hook detects first swap direction', type: 'bot' },
  { label: 'Victim Swaps', detail: 'User buys 2 ETH — hook counts 2nd swap in block', type: 'victim' },
  { label: 'Sandwich Detected', detail: 'Bot sells (opposite direction + ≥2 swaps) → SandwichDetected event', type: 'detection' },
  { label: 'BLS Task Created', detail: 'Hook auto-triggers createScoreTask → operators evaluate', type: 'score' },
  { label: 'Score = 55', detail: 'BLS quorum responds: fee escalates to 0.75% (was 0.30%)', type: 'score' },
  { label: 'Bot Tries Again', detail: 'Next sandwich attempt — pays 2.5x the fee, profit margin gone', type: 'bot' },
  { label: 'Score = 85', detail: 'Quorum bumps score → BotRejected revert, swap blocked', type: 'reject' },
  { label: 'LP Protected', detail: 'Escalated fees earned by LPs, bot fully expelled', type: 'lp' },
];

function calcFee(score: number): number {
  if (score >= 80) return -1;
  if (score < 40) return 3000;
  return 3000 + (15000 - 3000) * (score - 40) / 40;
}

export default function MEVProtectionSim() {
  const [activeStep, setActiveStep] = useState(-1);
  const [isPlaying, setIsPlaying] = useState(false);
  const [mode, setMode] = useState<'unprotected' | 'protected'>('unprotected');
  const timerRef = useRef<ReturnType<typeof setTimeout>>(undefined);

  const timeline = mode === 'protected' ? PROTECTED_TIMELINE : UNPROTECTED_TIMELINE;

  useEffect(() => {
    return () => { if (timerRef.current) clearTimeout(timerRef.current); };
  }, []);

  useEffect(() => {
    if (!isPlaying) return;
    if (activeStep >= timeline.length - 1) {
      setIsPlaying(false);
      return;
    }
    timerRef.current = setTimeout(() => setActiveStep(s => s + 1), 1400);
    return () => { if (timerRef.current) clearTimeout(timerRef.current); };
  }, [isPlaying, activeStep, timeline.length]);

  const play = () => {
    setActiveStep(0);
    setIsPlaying(true);
  };

  const switchMode = (m: 'unprotected' | 'protected') => {
    setMode(m);
    setActiveStep(-1);
    setIsPlaying(false);
  };

  const scores = [0, 15, 35, 55, 75, 85, 95];

  return (
    <div className="mev-sim">
      <div className="card">
        <div className="card-title">MEV Protection — Sandwich Attack Simulation</div>

        <div className="sim-mode-toggle">
          <button
            className={`sim-mode-btn ${mode === 'unprotected' ? 'active-unprotected' : ''}`}
            onClick={() => switchMode('unprotected')}
          >
            Without GradientShield
          </button>
          <button
            className={`sim-mode-btn ${mode === 'protected' ? 'active-protected' : ''}`}
            onClick={() => switchMode('protected')}
          >
            With GradientShield
          </button>
        </div>

        <div className="sim-timeline">
          {timeline.map((evt, i) => (
            <div
              key={`${mode}-${i}`}
              className={`sim-step ${i <= activeStep ? 'visible' : ''} step-${evt.type}`}
            >
              <div className="step-marker">
                <div className={`step-dot dot-${evt.type}`} />
                {i < timeline.length - 1 && <div className="step-line" />}
              </div>
              <div className="step-content">
                <strong>{evt.label}</strong>
                <span>{evt.detail}</span>
              </div>
            </div>
          ))}
        </div>

        <button className="btn btn-primary sim-play-btn" onClick={play} disabled={isPlaying}>
          {isPlaying ? 'Playing...' : activeStep >= 0 ? 'Replay' : 'Run Simulation'}
        </button>

        {mode === 'unprotected' && activeStep >= timeline.length - 1 && (
          <div className="sim-outcome outcome-bad">
            <strong>Result: Unprotected Pool</strong>
            <p>The bot extracts ~$980 per sandwich. LPs suffer impermanent loss. Over time, LPs withdraw — liquidity dries up.</p>
          </div>
        )}

        {mode === 'protected' && activeStep >= timeline.length - 1 && (
          <div className="sim-outcome outcome-good">
            <strong>Result: GradientShield Protected</strong>
            <p>1st attempt: detected, fee escalated 2.5x. 2nd attempt: fee at 3.5x, no profit margin. 3rd attempt: swap reverted. LP keeps all value.</p>
          </div>
        )}
      </div>

      <div className="card">
        <div className="card-title">Fee Escalation Curve — Live from Hook</div>
        <p className="sim-subtitle">Real values from <code>GradientShieldHook._computeFee()</code></p>

        <div className="fee-escalation-table">
          <div className="fee-row fee-header">
            <span>Score</span>
            <span>Band</span>
            <span>Fee (bps)</span>
            <span>Fee %</span>
            <span>vs Clean</span>
          </div>
          {scores.map(s => {
            const fee = calcFee(s);
            const rejected = fee === -1;
            const band = rejected ? 'Rejected' : s < 40 ? 'Clean' : 'Suspicious';
            const badgeClass = rejected ? 'badge-red' : s < 40 ? 'badge-green' : 'badge-yellow';
            const multiplier = rejected ? '---' : `${(fee / 3000).toFixed(1)}x`;
            return (
              <div key={s} className={`fee-row ${rejected ? 'fee-rejected' : ''}`}>
                <span className="fee-score">{s}</span>
                <span><span className={`badge ${badgeClass}`}>{band}</span></span>
                <span>{rejected ? '---' : fee.toFixed(0)}</span>
                <span>{rejected ? 'REVERTED' : `${(fee / 10000).toFixed(2)}%`}</span>
                <span className={fee > 3000 ? 'fee-multiplier' : ''}>{multiplier}</span>
              </div>
            );
          })}
        </div>

        <div className="fee-formula-box">
          <strong>Hook Formula (Solidity)</strong>
          <code>fee = BASE_FEE + (MAX_FEE - BASE_FEE) * (score - 40) / 40</code>
          <span className="formula-note">BASE_FEE = 3000 pips (0.30%) | MAX_FEE = 15000 pips (1.50%) | Reject ≥ 80</span>
        </div>
      </div>
    </div>
  );
}
