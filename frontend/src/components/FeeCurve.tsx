import { useMemo } from 'react';
import { XAxis, YAxis, CartesianGrid, Tooltip, ReferenceLine, ResponsiveContainer, Area, AreaChart, Line } from 'recharts';
import './FeeCurve.css';

export default function FeeCurve() {
  const data = useMemo(() => {
    const points = [];
    for (let score = 0; score <= 100; score++) {
      let fee: number | null;
      if (score >= 80) {
        fee = null;
      } else if (score < 40) {
        fee = 0.30;
      } else {
        fee = 0.30 + (1.50 - 0.30) * (score - 40) / (80 - 40);
      }
      points.push({ score, fee, rejected: score >= 80 ? 1.8 : null });
    }
    return points;
  }, []);

  return (
    <div className="card fee-curve">
      <div className="card-title">
        <span className="icon">&#128200;</span>
        Continuous Fee Curve
      </div>

      <div className="fee-legend">
        <div className="legend-item">
          <span className="legend-dot" style={{ background: '#22c55e' }} />
          <span>Clean (0-39): 0.30%</span>
        </div>
        <div className="legend-item">
          <span className="legend-dot" style={{ background: '#eab308' }} />
          <span>Suspicious (40-79): 0.30%-1.50%</span>
        </div>
        <div className="legend-item">
          <span className="legend-dot" style={{ background: '#ef4444' }} />
          <span>Rejected (80+): Reverted</span>
        </div>
      </div>

      <div className="chart-container">
        <ResponsiveContainer width="100%" height={220}>
          <AreaChart data={data} margin={{ top: 5, right: 10, left: -10, bottom: 5 }}>
            <defs>
              <linearGradient id="feeGradient" x1="0" y1="0" x2="1" y2="0">
                <stop offset="0%" stopColor="#22c55e" />
                <stop offset="40%" stopColor="#22c55e" />
                <stop offset="60%" stopColor="#eab308" />
                <stop offset="80%" stopColor="#f97316" />
              </linearGradient>
              <linearGradient id="feeAreaGradient" x1="0" y1="0" x2="0" y2="1">
                <stop offset="0%" stopColor="#3b82f6" stopOpacity={0.3} />
                <stop offset="100%" stopColor="#3b82f6" stopOpacity={0} />
              </linearGradient>
            </defs>
            <CartesianGrid strokeDasharray="3 3" stroke="#1e293b" />
            <XAxis
              dataKey="score"
              stroke="#64748b"
              fontSize={11}
              label={{ value: 'MEV Risk Score', position: 'insideBottom', offset: -2, fill: '#64748b', fontSize: 11 }}
            />
            <YAxis
              stroke="#64748b"
              fontSize={11}
              tickFormatter={(v) => `${v}%`}
              domain={[0, 2]}
            />
            <Tooltip
              contentStyle={{ background: '#1a2236', border: '1px solid #2a3650', borderRadius: '8px', fontSize: '13px' }}
              labelStyle={{ color: '#94a3b8' }}
              formatter={((value: number | string | undefined, name: string) => {
                if (name === 'rejected') return ['REVERTED', 'Status'];
                return typeof value === 'number' ? [`${value.toFixed(2)}%`, 'Fee'] : ['N/A', 'Fee'];
              }) as never}
              labelFormatter={(label) => `Score: ${label}`}
            />
            <ReferenceLine x={40} stroke="#eab308" strokeDasharray="4 4" strokeOpacity={0.5} />
            <ReferenceLine x={80} stroke="#ef4444" strokeDasharray="4 4" strokeOpacity={0.5} />
            <Area
              type="stepAfter"
              dataKey="fee"
              stroke="url(#feeGradient)"
              strokeWidth={2}
              fill="url(#feeAreaGradient)"
              dot={false}
              connectNulls={false}
            />
            <Line
              type="stepAfter"
              dataKey="rejected"
              stroke="#ef4444"
              strokeWidth={2}
              strokeDasharray="6 3"
              dot={false}
              connectNulls={false}
            />
          </AreaChart>
        </ResponsiveContainer>
      </div>

      <div className="fee-formula">
        <code>fee = 3000 + (15000 - 3000) * (score - 40) / 40</code>
      </div>
    </div>
  );
}
