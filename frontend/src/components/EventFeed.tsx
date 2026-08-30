import { useState, useEffect } from 'react';
import './EventFeed.css';

interface Event {
  id: number;
  type: 'swap' | 'sandwich' | 'jit' | 'escalation' | 'rejection';
  address: string;
  score: number;
  fee: string;
  pool: string;
  time: string;
  block: number;
}

const DEMO_EVENTS: Event[] = [
  { id: 1, type: 'swap', address: '0x1234...abcd', score: 0, fee: '0.30%', pool: 'ETH/USDC', time: '2s ago', block: 19234567 },
  { id: 2, type: 'swap', address: '0x5678...ef01', score: 12, fee: '0.30%', pool: 'ETH/USDC', time: '5s ago', block: 19234566 },
  { id: 3, type: 'escalation', address: '0x9abc...2345', score: 55, fee: '0.75%', pool: 'WBTC/ETH', time: '8s ago', block: 19234565 },
  { id: 4, type: 'sandwich', address: '0xdead...beef', score: 72, fee: '1.26%', pool: 'ETH/USDC', time: '12s ago', block: 19234564 },
  { id: 5, type: 'swap', address: '0xface...cafe', score: 5, fee: '0.30%', pool: 'DAI/USDC', time: '15s ago', block: 19234563 },
  { id: 6, type: 'jit', address: '0xb0b0...1111', score: 48, fee: '0.42%', pool: 'ETH/USDC', time: '20s ago', block: 19234562 },
  { id: 7, type: 'rejection', address: '0xbad0...bad0', score: 92, fee: 'REJECTED', pool: 'ETH/USDC', time: '25s ago', block: 19234561 },
  { id: 8, type: 'swap', address: '0xa1b2...c3d4', score: 0, fee: '0.30%', pool: 'LINK/ETH', time: '30s ago', block: 19234560 },
];

export default function EventFeed() {
  const [events, setEvents] = useState<Event[]>(DEMO_EVENTS);
  const [filter, setFilter] = useState<string>('all');

  useEffect(() => {
    const interval = setInterval(() => {
      const types: Event['type'][] = ['swap', 'swap', 'swap', 'sandwich', 'jit', 'escalation', 'rejection'];
      const type = types[Math.floor(Math.random() * types.length)];
      const score = type === 'swap' ? Math.floor(Math.random() * 30) :
                    type === 'sandwich' ? 60 + Math.floor(Math.random() * 20) :
                    type === 'jit' ? 40 + Math.floor(Math.random() * 20) :
                    type === 'escalation' ? 40 + Math.floor(Math.random() * 35) :
                    80 + Math.floor(Math.random() * 20);
      const fee = score >= 80 ? 'REJECTED' :
                  score < 40 ? '0.30%' :
                  `${(0.30 + (1.50 - 0.30) * (score - 40) / 40).toFixed(2)}%`;
      const addr = `0x${Math.random().toString(16).slice(2, 6)}...${Math.random().toString(16).slice(2, 6)}`;
      const pools = ['ETH/USDC', 'WBTC/ETH', 'DAI/USDC', 'LINK/ETH'];

      const newEvent: Event = {
        id: Date.now(),
        type,
        address: addr,
        score,
        fee,
        pool: pools[Math.floor(Math.random() * pools.length)],
        time: 'just now',
        block: 19234567 + Math.floor(Math.random() * 100),
      };

      setEvents(prev => [newEvent, ...prev.slice(0, 19)]);
    }, 3000);

    return () => clearInterval(interval);
  }, []);

  const filtered = filter === 'all' ? events : events.filter(e => e.type === filter);

  const typeIcon = (type: Event['type']) => {
    switch (type) {
      case 'swap': return '↔';
      case 'sandwich': return '⚠';
      case 'jit': return '⚡';
      case 'escalation': return '↑';
      case 'rejection': return '✖';
    }
  };

  const typeBadge = (type: Event['type']) => {
    switch (type) {
      case 'swap': return 'badge-green';
      case 'sandwich': return 'badge-red';
      case 'jit': return 'badge-yellow';
      case 'escalation': return 'badge-yellow';
      case 'rejection': return 'badge-red';
    }
  };

  return (
    <div className="card event-feed">
      <div className="event-feed-header">
        <div className="card-title">
          <span className="icon">&#9889;</span>
          Live Event Feed
          <span className="live-dot" />
        </div>
        <div className="event-filters">
          {['all', 'swap', 'sandwich', 'jit', 'escalation', 'rejection'].map(f => (
            <button
              key={f}
              className={`filter-btn ${filter === f ? 'active' : ''}`}
              onClick={() => setFilter(f)}
            >
              {f === 'all' ? 'All' : f.charAt(0).toUpperCase() + f.slice(1)}
            </button>
          ))}
        </div>
      </div>

      <div className="event-table-wrap">
        <table className="event-table">
          <thead>
            <tr>
              <th>Type</th>
              <th>Address</th>
              <th>Score</th>
              <th>Fee</th>
              <th>Pool</th>
              <th>Block</th>
              <th>Time</th>
            </tr>
          </thead>
          <tbody>
            {filtered.map(event => (
              <tr key={event.id} className={`event-row event-${event.type}`}>
                <td>
                  <span className={`badge ${typeBadge(event.type)}`}>
                    {typeIcon(event.type)} {event.type}
                  </span>
                </td>
                <td className="mono">{event.address}</td>
                <td>
                  <span className={`score-pill ${event.score >= 80 ? 'red' : event.score >= 40 ? 'yellow' : 'green'}`}>
                    {event.score}
                  </span>
                </td>
                <td className={event.fee === 'REJECTED' ? 'rejected-text' : ''}>{event.fee}</td>
                <td>{event.pool}</td>
                <td className="mono">{event.block}</td>
                <td className="time-cell">{event.time}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
