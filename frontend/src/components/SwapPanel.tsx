import { useState } from 'react';
import './SwapPanel.css';

const ORACLE_ADDRESS = '0x019d874fdfea12ddcb729ab0abb0a34202652289';
const ETHERSCAN = 'https://sepolia.etherscan.io';

const PRICE_MAP: Record<string, number> = {
  'ETH-USDC': 2450, 'USDC-ETH': 1 / 2450,
  'ETH-DAI': 2450, 'DAI-ETH': 1 / 2450,
  'ETH-WBTC': 0.04, 'WBTC-ETH': 25,
  'USDC-DAI': 1, 'DAI-USDC': 1,
  'USDC-WBTC': 1 / 61000, 'WBTC-USDC': 61000,
  'DAI-WBTC': 1 / 61000, 'WBTC-DAI': 61000,
  'ETH-LINK': 170, 'LINK-ETH': 1 / 170,
  'USDC-LINK': 1 / 14.4, 'LINK-USDC': 14.4,
  'DAI-LINK': 1 / 14.4, 'LINK-DAI': 14.4,
  'WBTC-LINK': 4236, 'LINK-WBTC': 1 / 4236,
};

function calcFee(score: number): { bps: number; label: string; band: string; badgeClass: string } {
  if (score >= 80) return { bps: -1, label: 'REJECTED', band: 'Rejected', badgeClass: 'badge-red' };
  if (score < 40) return { bps: 3000, label: '0.30%', band: 'Clean', badgeClass: 'badge-green' };
  const bps = 3000 + (15000 - 3000) * (score - 40) / 40;
  return { bps, label: `${(bps / 10000).toFixed(2)}%`, band: 'Suspicious', badgeClass: 'badge-yellow' };
}

interface Props {
  isConnected: boolean;
  address?: `0x${string}`;
}

export default function SwapPanel({ isConnected }: Props) {
  const [fromToken, setFromToken] = useState('ETH');
  const [toToken, setToToken] = useState('USDC');
  const [amount, setAmount] = useState('1.0');
  const [slippage, setSlippage] = useState('0.5');
  const [demoScore, setDemoScore] = useState(15);

  const tokens = ['ETH', 'USDC', 'WBTC', 'DAI', 'LINK'];
  const fee = calcFee(demoScore);
  const pair = `${fromToken}-${toToken}`;
  const directPrice = PRICE_MAP[pair];
  const needsMultiHop = !directPrice && fromToken !== toToken;
  const price = directPrice ?? (PRICE_MAP[`${fromToken}-ETH`] && PRICE_MAP[`ETH-${toToken}`]
    ? PRICE_MAP[`${fromToken}-ETH`]! * PRICE_MAP[`ETH-${toToken}`]!
    : 1);
  const route = fromToken === toToken ? fromToken : needsMultiHop ? `${fromToken} → ETH → ${toToken}` : `${fromToken} → ${toToken}`;
  const hops = needsMultiHop ? 2 : 1;
  const inputNum = parseFloat(amount) || 0;

  const isRejected = fee.bps === -1;
  const feeMultiplier = isRejected ? 0 : 1 - fee.bps / 1_000_000;
  const outputBeforeFee = inputNum * price;
  const outputAfterFee = isRejected ? 0 : outputBeforeFee * feeMultiplier;
  const feeAmount = isRejected ? 0 : outputBeforeFee - outputAfterFee;

  const noFeeOutput = inputNum * price * (1 - 3000 / 1_000_000);
  const extraFeeCost = isRejected ? outputBeforeFee : (noFeeOutput - outputAfterFee);

  const handleSwapTokens = () => {
    const tmp = fromToken;
    setFromToken(toToken);
    setToToken(tmp);
  };

  const scoreColor = demoScore >= 80 ? 'var(--red)' : demoScore >= 40 ? 'var(--yellow)' : 'var(--green)';

  return (
    <div className="swap-container">
      <div className="card swap-panel">
        <div className="card-title">Swap (GradientShield Protected)</div>

        <div className="demo-score-control">
          <div className="demo-score-header">
            <span className="demo-score-label">Simulate MEV Risk Score</span>
            <span className="demo-score-value" style={{ color: scoreColor }}>{demoScore}</span>
          </div>
          <input
            type="range" min="0" max="100" value={demoScore}
            onChange={(e) => setDemoScore(Number(e.target.value))}
            className="slider"
            style={{ accentColor: scoreColor }}
          />
          <div className="demo-score-presets">
            <button className="preset-btn preset-clean" onClick={() => setDemoScore(10)}>Clean User (10)</button>
            <button className="preset-btn preset-suspicious" onClick={() => setDemoScore(55)}>Suspicious (55)</button>
            <button className="preset-btn preset-bot" onClick={() => setDemoScore(75)}>MEV Bot (75)</button>
            <button className="preset-btn preset-rejected" onClick={() => setDemoScore(90)}>Blocked Bot (90)</button>
          </div>
        </div>

        <div className="swap-form">
          <div className="swap-input-box">
            <div className="swap-input-header">
              <span className="swap-label">From</span>
              <span className="swap-balance">Balance: {isConnected ? '10.00' : '--'}</span>
            </div>
            <div className="swap-input-row">
              <input
                className="swap-amount-input"
                type="number"
                placeholder="0.0"
                value={amount}
                onChange={(e) => setAmount(e.target.value)}
              />
              <select className="token-select" value={fromToken} onChange={(e) => setFromToken(e.target.value)}>
                {tokens.map(t => <option key={t} value={t}>{t}</option>)}
              </select>
            </div>
          </div>

          <button className="swap-direction-btn" onClick={handleSwapTokens}>&#8597;</button>

          <div className="swap-input-box">
            <div className="swap-input-header">
              <span className="swap-label">To {isRejected && <span className="rejected-inline">SWAP REJECTED</span>}</span>
              <span className="swap-balance">Balance: {isConnected ? '0.00' : '--'}</span>
            </div>
            <div className="swap-input-row">
              <input
                className={`swap-amount-input ${isRejected ? 'rejected-output' : ''}`}
                type="text"
                placeholder="0.0"
                value={isRejected ? 'REJECTED' : (inputNum ? outputAfterFee.toFixed(4) : '')}
                readOnly
              />
              <select className="token-select" value={toToken} onChange={(e) => setToToken(e.target.value)}>
                {tokens.map(t => <option key={t} value={t}>{t}</option>)}
              </select>
            </div>
          </div>

          {inputNum > 0 && !isRejected && (
            <div className="swap-breakdown">
              <div className="breakdown-row">
                <span>Rate</span>
                <span>1 {fromToken} = {price.toFixed(price < 1 ? 6 : 2)} {toToken}</span>
              </div>
              <div className="breakdown-row">
                <span>Hook Fee ({fee.label})</span>
                <span>-{feeAmount.toFixed(4)} {toToken}</span>
              </div>
              {fee.bps > 3000 && (
                <div className="breakdown-row extra-fee">
                  <span>Extra vs. clean user</span>
                  <span>-{extraFeeCost.toFixed(4)} {toToken}</span>
                </div>
              )}
              <div className="breakdown-row total">
                <span>You receive</span>
                <span>{outputAfterFee.toFixed(4)} {toToken}</span>
              </div>
            </div>
          )}

          {isRejected && inputNum > 0 && (
            <div className="rejected-banner">
              <span className="rejected-icon">&#128683;</span>
              <div>
                <strong>Transaction Reverted</strong>
                <p>Score {demoScore} exceeds threshold (80). The hook's beforeSwap reverts to protect the pool from MEV extraction.</p>
              </div>
            </div>
          )}

          <button
            className={`btn swap-btn ${isRejected ? 'btn-rejected' : 'btn-primary'}`}
            disabled={!isConnected || !inputNum || isRejected}
          >
            {!isConnected ? 'Connect Wallet' : !inputNum ? 'Enter Amount' : isRejected ? 'Swap Blocked — Score Too High' : 'Swap'}
          </button>
        </div>
      </div>

      <div className="card swap-info">
        <div className="card-title">MEV Protection Breakdown</div>

        <div className="protection-details">
          <div className="protection-row">
            <span className="protection-label">MEV Risk Score</span>
            <span className="protection-value">
              <span className={`badge ${fee.badgeClass}`} style={{ fontSize: '14px' }}>{demoScore}</span>
            </span>
          </div>
          <div className="protection-row">
            <span className="protection-label">Score Band</span>
            <span className={`protection-value badge ${fee.badgeClass}`}>{fee.band}</span>
          </div>
          <div className="protection-row">
            <span className="protection-label">Hook Fee</span>
            <span className="protection-value" style={{ color: isRejected ? 'var(--red)' : undefined }}>
              {fee.label}
            </span>
          </div>
          {!isRejected && (
            <div className="protection-row">
              <span className="protection-label">Fee (bps)</span>
              <span className="protection-value">{fee.bps.toFixed(0)} / 1,000,000</span>
            </div>
          )}
          <div className="protection-row">
            <span className="protection-label">Settlement</span>
            <span className="protection-value">{needsMultiHop ? 'ERC6909 Claims' : 'Direct'}</span>
          </div>
          <div className="protection-row">
            <span className="protection-label">Route ({hops} hop{hops > 1 ? 's' : ''})</span>
            <span className="protection-value">{route}</span>
          </div>

          <div className="swap-settings" style={{ marginTop: '8px' }}>
            <div className="setting-row">
              <span>Slippage Tolerance</span>
              <div className="slippage-options">
                {['0.1', '0.5', '1.0'].map(s => (
                  <button key={s} className={`slippage-btn ${slippage === s ? 'active' : ''}`} onClick={() => setSlippage(s)}>
                    {s}%
                  </button>
                ))}
              </div>
            </div>
          </div>

          <div className="contract-links">
            <h4>Deployed Contracts (Sepolia)</h4>
            <a href={`${ETHERSCAN}/address/${ORACLE_ADDRESS}`} target="_blank" rel="noopener noreferrer" className="contract-link">
              ScoringOracle: {ORACLE_ADDRESS.slice(0, 8)}...{ORACLE_ADDRESS.slice(-6)}
              <span className="link-icon">&#8599;</span>
            </a>
          </div>

          <div className="fee-formula-box">
            <strong>Fee Formula</strong>
            <code>fee = 3000 + (15000 - 3000) × (score - 40) / 40</code>
            <span className="formula-note">Score &lt; 40: base fee (0.30%) | Score 40-79: escalating | Score ≥ 80: reverted</span>
          </div>
        </div>
      </div>
    </div>
  );
}
