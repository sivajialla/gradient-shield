import { useState } from 'react';
import './TaskDashboard.css';

interface Task {
  id: number;
  subject: string;
  fromBlock: number;
  toBlock: number;
  quorumThreshold: number;
  status: 'pending' | 'responded' | 'challenged';
  score?: number;
  trigger: string;
  createdAt: string;
}

const DEMO_TASKS: Task[] = [
  { id: 0, subject: '0xdead...beef', fromBlock: 19234550, toBlock: 19234560, quorumThreshold: 67, status: 'responded', score: 72, trigger: 'sandwich', createdAt: '2 min ago' },
  { id: 1, subject: '0xb0b0...1111', fromBlock: 19234555, toBlock: 19234565, quorumThreshold: 67, status: 'responded', score: 48, trigger: 'jit', createdAt: '5 min ago' },
  { id: 2, subject: '0x9abc...2345', fromBlock: 19234540, toBlock: 19234550, quorumThreshold: 67, status: 'pending', trigger: 'sandwich', createdAt: '8 min ago' },
  { id: 3, subject: '0xbad0...bad0', fromBlock: 19234530, toBlock: 19234540, quorumThreshold: 67, status: 'responded', score: 92, trigger: 'stale', createdAt: '15 min ago' },
  { id: 4, subject: '0xface...cafe', fromBlock: 19234520, toBlock: 19234530, quorumThreshold: 67, status: 'challenged', score: 0, trigger: 'sandwich', createdAt: '22 min ago' },
];

export default function TaskDashboard() {
  const [tasks] = useState<Task[]>(DEMO_TASKS);

  const statusBadge = (status: Task['status']) => {
    switch (status) {
      case 'pending': return 'badge-yellow';
      case 'responded': return 'badge-green';
      case 'challenged': return 'badge-red';
    }
  };

  const triggerIcon = (trigger: string) => {
    switch (trigger) {
      case 'sandwich': return '&#x1F96A;';
      case 'jit': return '&#x26A1;';
      case 'stale': return '&#x23F0;';
      default: return '&#x2753;';
    }
  };

  return (
    <div className="task-dashboard">
      <div className="task-stats">
        <div className="card stat-card">
          <div className="stat-value">{tasks.length}</div>
          <div className="stat-label">Total Tasks</div>
        </div>
        <div className="card stat-card">
          <div className="stat-value stat-green">{tasks.filter(t => t.status === 'responded').length}</div>
          <div className="stat-label">Responded</div>
        </div>
        <div className="card stat-card">
          <div className="stat-value stat-yellow">{tasks.filter(t => t.status === 'pending').length}</div>
          <div className="stat-label">Pending</div>
        </div>
        <div className="card stat-card">
          <div className="stat-value stat-red">{tasks.filter(t => t.status === 'challenged').length}</div>
          <div className="stat-label">Challenged</div>
        </div>
      </div>

      <div className="card">
        <div className="card-title">BLS Scoring Tasks</div>

        <div className="task-table-wrap">
          <table className="task-table">
            <thead>
              <tr>
                <th>Task #</th>
                <th>Subject</th>
                <th>Trigger</th>
                <th>Block Range</th>
                <th>Quorum</th>
                <th>Status</th>
                <th>Score</th>
                <th>Created</th>
              </tr>
            </thead>
            <tbody>
              {tasks.map(task => (
                <tr key={task.id} className="task-row">
                  <td className="mono">#{task.id}</td>
                  <td className="mono">{task.subject}</td>
                  <td>
                    <span className="trigger-badge" dangerouslySetInnerHTML={{ __html: triggerIcon(task.trigger) }} />
                    {' '}{task.trigger}
                  </td>
                  <td className="mono">{task.fromBlock} - {task.toBlock}</td>
                  <td>{task.quorumThreshold}%</td>
                  <td>
                    <span className={`badge ${statusBadge(task.status)}`}>
                      {task.status}
                    </span>
                  </td>
                  <td>
                    {task.score !== undefined ? (
                      <span className={`score-pill ${task.score >= 80 ? 'red' : task.score >= 40 ? 'yellow' : 'green'}`}>
                        {task.score}
                      </span>
                    ) : (
                      <span className="pending-dots">...</span>
                    )}
                  </td>
                  <td className="time-cell">{task.createdAt}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>

      <div className="card">
        <div className="card-title">BLS Quorum Flow</div>
        <div className="quorum-flow">
          <div className="flow-step">
            <div className="flow-circle">1</div>
            <div className="flow-content">
              <strong>Detection</strong>
              <p>Hook detects sandwich/JIT pattern on-chain via transient storage</p>
            </div>
          </div>
          <div className="flow-arrow">&#8594;</div>
          <div className="flow-step">
            <div className="flow-circle">2</div>
            <div className="flow-content">
              <strong>Task Created</strong>
              <p>createScoreTask() emitted on TaskManager (rate-limited: 1 per 50 blocks)</p>
            </div>
          </div>
          <div className="flow-arrow">&#8594;</div>
          <div className="flow-step">
            <div className="flow-circle">3</div>
            <div className="flow-content">
              <strong>BLS Consensus</strong>
              <p>Operators independently score, sign with BLS keys, aggregator collects</p>
            </div>
          </div>
          <div className="flow-arrow">&#8594;</div>
          <div className="flow-step">
            <div className="flow-circle">4</div>
            <div className="flow-content">
              <strong>On-chain Verification</strong>
              <p>BN254 pairing check (~120k gas), quorum threshold verified, score written</p>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
