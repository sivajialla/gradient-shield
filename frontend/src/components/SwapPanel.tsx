import { useState } from 'react';
import './SwapPanel.css';

interface Props {
  isConnected: boolean;
  address?: `0x${string}`;
}

export default function SwapPanel({ isConnected }: Props) {
  const [fromToken, setFromToken] = useState('ETH');
  const [toToken, setToToken] = useState('USDC');
  const [amount, setAmount] = useState('');
  const [slippage, setSlippage] = useState('0.5');
  const [useMultiHop, setUseMultiHop] = useState(false);

  const demoScore = 15;
  const demoFee = '0.30%';
  const demoOutput = amount ? (parseFloat(amount) * 2450 * 0.997).toFixed(2) : '0.00';

  const tokens = ['ETH', 'USDC', 'WBTC', 'DAI', 'LINK'];

  const handleSwapTokens = () => {
    const tmp = fromToken;
    setFromToken(toToken);
    setToToken(tmp);
  };

  return (
    <div className="swap-container">
      <div className="card swap-panel">
        <div className="card-title">
          <span className="icon">&#8644;</span>
          Swap (GradientShield Protected)
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

          <button className="swap-direction-btn" onClick={handleSwapTokens}>
            &#8597;
          </button>

          <div className="swap-input-box">
            <div className="swap-input-header">
              <span className="swap-label">To</span>
              <span className="swap-balance">Balance: {isConnected ? '0.00' : '--'}</span>
            </div>
            <div className="swap-input-row">
              <input
                className="swap-amount-input"
                type="text"
                placeholder="0.0"
                value={amount ? demoOutput : ''}
                readOnly
              />
              <select className="token-select" value={toToken} onChange={(e) => setToToken(e.target.value)}>
                {tokens.map(t => <option key={t} value={t}>{t}</option>)}
              </select>
            </div>
          </div>

          <div className="swap-settings">
            <div className="setting-row">
              <span>Slippage Tolerance</span>
              <div className="slippage-options">
                {['0.1', '0.5', '1.0'].map(s => (
                  <button
                    key={s}
                    className={`slippage-btn ${slippage === s ? 'active' : ''}`}
                    onClick={() => setSlippage(s)}
                  >
                    {s}%
                  </button>
                ))}
              </div>
            </div>
            <div className="setting-row">
              <span>Multi-hop (ERC6909)</span>
              <label className="toggle">
                <input type="checkbox" checked={useMultiHop} onChange={(e) => setUseMultiHop(e.target.checked)} />
                <span className="toggle-slider" />
              </label>
            </div>
          </div>

          <button className="btn btn-primary swap-btn" disabled={!isConnected || !amount}>
            {!isConnected ? 'Connect Wallet' : !amount ? 'Enter Amount' : 'Swap'}
          </button>
        </div>
      </div>

      <div className="card swap-info">
        <div className="card-title">
          <span className="icon">&#128737;</span>
          MEV Protection Details
        </div>

        <div className="protection-details">
          <div className="protection-row">
            <span className="protection-label">Your MEV Score</span>
            <span className="protection-value">
              <span className="badge badge-green">{demoScore}</span>
            </span>
          </div>
          <div className="protection-row">
            <span className="protection-label">Hook Fee</span>
            <span className="protection-value">{demoFee}</span>
          </div>
          <div className="protection-row">
            <span className="protection-label">Score Band</span>
            <span className="protection-value badge badge-green">Clean</span>
          </div>
          <div className="protection-row">
            <span className="protection-label">Settlement</span>
            <span className="protection-value">{useMultiHop ? 'ERC6909 Claims' : 'Direct'}</span>
          </div>
          <div className="protection-row">
            <span className="protection-label">Route</span>
            <span className="protection-value">
              {useMultiHop ? `${fromToken} -> WETH -> ${toToken}` : `${fromToken} -> ${toToken}`}
            </span>
          </div>

          <div className="protection-explainer">
            <h4>How GradientShield protects you</h4>
            <div className="explainer-steps">
              <div className="step">
                <div className="step-num">1</div>
                <div className="step-text">
                  <strong>beforeSwap</strong> reads your MEV risk score from the ScoringOracle
                </div>
              </div>
              <div className="step">
                <div className="step-num">2</div>
                <div className="step-text">
                  <strong>Sandwich/JIT detection</strong> uses transient storage to spot MEV patterns in the same block
                </div>
              </div>
              <div className="step">
                <div className="step-num">3</div>
                <div className="step-text">
                  <strong>Continuous fee curve</strong> applies a proportional fee — clean traders pay base fee (0.30%)
                </div>
              </div>
              <div className="step">
                <div className="step-num">4</div>
                <div className="step-text">
                  <strong>BLS quorum</strong> operators independently evaluate flagged addresses off-chain
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
