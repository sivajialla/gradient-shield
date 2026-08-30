import { useState, useMemo } from 'react';
import { AreaChart, Area, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer, Legend } from 'recharts';
import './SustainableLiquiditySim.css';

const DAYS = 30;
const DAILY_VOLUME = 500_000;

interface SimConfig {
  mevShare: number;
  cleanFee: number;
  mevFeeMultiplier: number;
  rejectedShare: number;
}

function simulate(config: SimConfig) {
  const data = [];
  let standardCum = 0;
  let shieldedCum = 0;
  let mevExtracted = 0;
  let mevBlocked = 0;

  for (let day = 1; day <= DAYS; day++) {
    const cleanVolume = DAILY_VOLUME * (1 - config.mevShare);
    const mevVolume = DAILY_VOLUME * config.mevShare * (1 - config.rejectedShare);
    const rejectedVolume = DAILY_VOLUME * config.mevShare * config.rejectedShare;

    const standardFeeRevenue = DAILY_VOLUME * (config.cleanFee / 100);
    const mevLoss = DAILY_VOLUME * config.mevShare * 0.005;
    const standardNet = standardFeeRevenue - mevLoss;

    const shieldedCleanFees = cleanVolume * (config.cleanFee / 100);
    const shieldedMevFees = mevVolume * (config.cleanFee / 100) * config.mevFeeMultiplier;
    const shieldedNet = shieldedCleanFees + shieldedMevFees;

    standardCum += standardNet;
    shieldedCum += shieldedNet;
    mevExtracted += mevLoss;
    mevBlocked += rejectedVolume * 0.005;

    data.push({
      day,
      standard: Math.round(standardCum),
      shielded: Math.round(shieldedCum),
      mevExtracted: Math.round(mevExtracted),
    });
  }

  return {
    data,
    totalStandard: Math.round(standardCum),
    totalShielded: Math.round(shieldedCum),
    totalMevBlocked: Math.round(mevBlocked),
    improvement: ((shieldedCum / standardCum - 1) * 100).toFixed(1),
  };
}

export default function SustainableLiquiditySim() {
  const [mevShare, setMevShare] = useState(15);
  const [rejectedShare, setRejectedShare] = useState(40);

  const config: SimConfig = {
    mevShare: mevShare / 100,
    cleanFee: 0.30,
    mevFeeMultiplier: 3.5,
    rejectedShare: rejectedShare / 100,
  };

  const result = useMemo(() => simulate(config), [mevShare, rejectedShare]);

  const formatDollar = (v: number) => `$${v.toLocaleString()}`;

  return (
    <div className="liq-sim">
      <div className="card">
        <div className="card-title">Sustainable Liquidity — LP Earnings Comparison</div>
        <p className="sim-subtitle">30-day simulation: Standard pool vs. GradientShield-protected pool</p>

        <div className="liq-controls">
          <div className="liq-control">
            <label>MEV Bot Traffic Share</label>
            <div className="liq-slider-row">
              <input
                type="range" min="5" max="40" value={mevShare}
                onChange={e => setMevShare(Number(e.target.value))}
                className="slider"
                style={{ accentColor: 'var(--accent)' }}
              />
              <span className="liq-value">{mevShare}%</span>
            </div>
          </div>
          <div className="liq-control">
            <label>Bots Rejected (score ≥ 80)</label>
            <div className="liq-slider-row">
              <input
                type="range" min="0" max="80" value={rejectedShare}
                onChange={e => setRejectedShare(Number(e.target.value))}
                className="slider"
                style={{ accentColor: 'var(--red)' }}
              />
              <span className="liq-value">{rejectedShare}%</span>
            </div>
          </div>
        </div>

        <div className="liq-chart-wrap">
          <ResponsiveContainer width="100%" height={280}>
            <AreaChart data={result.data} margin={{ top: 8, right: 8, left: 0, bottom: 0 }}>
              <CartesianGrid strokeDasharray="3 3" stroke="var(--chart-grid)" />
              <XAxis
                dataKey="day"
                stroke="var(--text-muted)"
                fontSize={11}
                tickFormatter={d => `D${d}`}
              />
              <YAxis
                stroke="var(--text-muted)"
                fontSize={11}
                tickFormatter={v => `$${(v / 1000).toFixed(0)}k`}
              />
              <Tooltip
                contentStyle={{
                  background: 'var(--bg-card)',
                  border: '1px solid var(--border)',
                  borderRadius: '8px',
                  fontSize: '12px',
                }}
                formatter={((v: number) => [`$${v.toLocaleString()}`, '']) as never}
                labelFormatter={d => `Day ${d}`}
              />
              <Legend wrapperStyle={{ fontSize: '12px' }} />
              <Area
                type="monotone"
                dataKey="standard"
                name="Standard Pool LP Fees"
                stroke="var(--text-muted)"
                fill="var(--border)"
                strokeWidth={2}
                fillOpacity={0.3}
              />
              <Area
                type="monotone"
                dataKey="shielded"
                name="GradientShield LP Fees"
                stroke="#FC72FF"
                fill="#FC72FF"
                strokeWidth={2}
                fillOpacity={0.15}
              />
              <Area
                type="monotone"
                dataKey="mevExtracted"
                name="MEV Extracted (unprotected)"
                stroke="var(--red)"
                fill="var(--red)"
                strokeWidth={1}
                fillOpacity={0.1}
                strokeDasharray="4 4"
              />
            </AreaChart>
          </ResponsiveContainer>
        </div>
      </div>

      <div className="card">
        <div className="card-title">30-Day Results</div>

        <div className="liq-results">
          <div className="liq-stat">
            <span className="liq-stat-label">Standard Pool LP Earnings</span>
            <span className="liq-stat-value" style={{ color: 'var(--text-muted)' }}>
              {formatDollar(result.totalStandard)}
            </span>
          </div>
          <div className="liq-stat">
            <span className="liq-stat-label">GradientShield LP Earnings</span>
            <span className="liq-stat-value" style={{ color: 'var(--accent)' }}>
              {formatDollar(result.totalShielded)}
            </span>
          </div>
          <div className="liq-stat highlight-stat">
            <span className="liq-stat-label">LP Earnings Improvement</span>
            <span className="liq-stat-value" style={{ color: 'var(--green)' }}>
              +{result.improvement}%
            </span>
          </div>
          <div className="liq-stat">
            <span className="liq-stat-label">MEV Value Blocked</span>
            <span className="liq-stat-value" style={{ color: 'var(--red)' }}>
              {formatDollar(result.totalMevBlocked)}
            </span>
          </div>
        </div>

        <div className="liq-how-it-works">
          <div className="card-title" style={{ fontSize: '15px', marginBottom: '12px' }}>How It Works</div>

          <div className="how-row">
            <div className="how-icon" style={{ background: 'var(--green-bg)', color: 'var(--green)' }}>1</div>
            <div className="how-content">
              <strong>Clean users pay base fee (0.30%)</strong>
              <span>Competitive with standard Uniswap pools — no penalty for honest traders</span>
            </div>
          </div>

          <div className="how-row">
            <div className="how-icon" style={{ background: 'var(--yellow-bg)', color: 'var(--yellow)' }}>2</div>
            <div className="how-content">
              <strong>MEV bots pay escalated fees (up to 1.50%)</strong>
              <span>Hook's continuous fee curve prices in MEV risk — bot fees go directly to LPs</span>
            </div>
          </div>

          <div className="how-row">
            <div className="how-icon" style={{ background: 'var(--red-bg)', color: 'var(--red)' }}>3</div>
            <div className="how-content">
              <strong>Worst bots are fully rejected (score ≥ 80)</strong>
              <span>beforeSwap reverts with BotRejected — zero value extracted from the pool</span>
            </div>
          </div>

          <div className="how-row">
            <div className="how-icon" style={{ background: 'var(--accent-soft)', color: 'var(--accent)' }}>4</div>
            <div className="how-content">
              <strong>Score decay rewards reformed behavior</strong>
              <span>Oracle decays 5 pts/day — stopped bots heal to clean within 2 weeks</span>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
