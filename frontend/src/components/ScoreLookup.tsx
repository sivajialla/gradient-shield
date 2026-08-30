import { useState } from 'react';
import { useReadContract } from 'wagmi';
import { CONTRACTS } from '../config';
import { ScoringOracleABI } from '../abi/ScoringOracle';
import './ScoreLookup.css';

interface Props {
  connectedAddress?: `0x${string}`;
}

export default function ScoreLookup({ connectedAddress }: Props) {
  const [inputAddr, setInputAddr] = useState('');
  const lookupAddr = (inputAddr || connectedAddress || '') as `0x${string}`;
  const isValidAddr = /^0x[0-9a-fA-F]{40}$/.test(lookupAddr);

  const { data: score, isLoading, refetch } = useReadContract({
    address: CONTRACTS.scoringOracle,
    abi: ScoringOracleABI,
    functionName: 'getScore',
    args: isValidAddr ? [lookupAddr] : undefined,
    query: { enabled: isValidAddr && CONTRACTS.scoringOracle !== '0x0000000000000000000000000000000000000000' },
  });

  const { data: rawRecord } = useReadContract({
    address: CONTRACTS.scoringOracle,
    abi: ScoringOracleABI,
    functionName: 'rawRecord',
    args: isValidAddr ? [lookupAddr] : undefined,
    query: { enabled: isValidAddr && CONTRACTS.scoringOracle !== '0x0000000000000000000000000000000000000000' },
  });

  const scoreNum = typeof score === 'number' ? score : Number(score ?? 0);
  const record = rawRecord as unknown as { score: number; lastUpdated: number } | undefined;
  const rawScoreNum = record ? Number(record.score) : 0;
  const lastUpdated = record ? Number(record.lastUpdated) : 0;

  const getScoreBand = (s: number) => {
    if (s >= 80) return { label: 'Rejected', className: 'score-rejected', color: '#ef4444' };
    if (s >= 40) return { label: 'Suspicious', className: 'score-suspicious', color: '#eab308' };
    return { label: 'Clean', className: 'score-clean', color: '#22c55e' };
  };

  const feeForScore = (s: number) => {
    if (s >= 80) return 'REJECTED';
    if (s < 40) return '0.30%';
    const fee = 3000 + (15000 - 3000) * (s - 40) / (80 - 40);
    return `${(fee / 10000 * 100).toFixed(2)}%`;
  };

  const decayAmount = rawScoreNum - scoreNum;
  const formatTime = (ts: number) => {
    if (!ts) return 'Never';
    const d = new Date(ts * 1000);
    return d.toLocaleDateString() + ' ' + d.toLocaleTimeString();
  };

  // Demo mode: use simulated score if no contract deployed
  const isDemo = CONTRACTS.scoringOracle === '0x0000000000000000000000000000000000000000';
  const [demoScore, setDemoScore] = useState(0);
  const displayScore = isDemo ? demoScore : scoreNum;
  const displayBand = getScoreBand(displayScore);

  return (
    <div className="card score-lookup">
      <div className="card-title">Score Lookup</div>

      <div className="input-group">
        <input
          className="input-field"
          type="text"
          placeholder={connectedAddress ? `${connectedAddress.slice(0, 10)}... (connected)` : '0x address...'}
          value={inputAddr}
          onChange={(e) => setInputAddr(e.target.value)}
        />
        <button className="btn btn-primary" onClick={() => refetch()} disabled={!isValidAddr && !isDemo}>
          {isLoading ? '...' : 'Lookup'}
        </button>
      </div>

      {isDemo && (
        <div className="demo-slider">
          <label className="slider-label">
            Demo Score: <strong>{demoScore}</strong>
          </label>
          <input
            type="range"
            min="0"
            max="100"
            value={demoScore}
            onChange={(e) => setDemoScore(Number(e.target.value))}
            className="slider"
          />
        </div>
      )}

      <div className="score-display">
        <div className="score-gauge">
          <svg viewBox="0 0 120 120" className="gauge-svg">
            <circle cx="60" cy="60" r="50" fill="none" stroke="var(--gauge-track)" strokeWidth="10" />
            <circle
              cx="60" cy="60" r="50"
              fill="none"
              stroke={displayBand.color}
              strokeWidth="10"
              strokeDasharray={`${(displayScore / 100) * 314} 314`}
              strokeLinecap="round"
              transform="rotate(-90 60 60)"
              style={{ transition: 'stroke-dasharray 0.5s ease' }}
            />
            <text x="60" y="55" textAnchor="middle" fill={displayBand.color} fontSize="28" fontWeight="700">
              {displayScore}
            </text>
            <text x="60" y="75" textAnchor="middle" fill="var(--text-secondary)" fontSize="11">
              {displayBand.label}
            </text>
          </svg>
        </div>

        <div className="score-details">
          <div className="detail-row">
            <span className="detail-label">Current Fee</span>
            <span className="detail-value">{feeForScore(displayScore)}</span>
          </div>
          {!isDemo && (
            <>
              <div className="detail-row">
                <span className="detail-label">Raw Score</span>
                <span className="detail-value">{rawScoreNum}</span>
              </div>
              <div className="detail-row">
                <span className="detail-label">Decay Applied</span>
                <span className="detail-value decay">-{decayAmount}</span>
              </div>
              <div className="detail-row">
                <span className="detail-label">Last Updated</span>
                <span className="detail-value small">{formatTime(lastUpdated)}</span>
              </div>
            </>
          )}
          {isDemo && (
            <>
              <div className="detail-row">
                <span className="detail-label">Decay Rate</span>
                <span className="detail-value">5 pts/day</span>
              </div>
              <div className="detail-row">
                <span className="detail-label">Status</span>
                <span className={`badge badge-${displayScore >= 80 ? 'red' : displayScore >= 40 ? 'yellow' : 'green'}`}>
                  {displayBand.label}
                </span>
              </div>
            </>
          )}
        </div>
      </div>
    </div>
  );
}
