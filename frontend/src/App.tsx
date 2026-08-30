import { useState, useEffect, useCallback } from 'react';
import { useAccount, useConnect, useDisconnect } from 'wagmi';
import { injected } from 'wagmi/connectors';
import Header from './components/Header';
import ScoreLookup from './components/ScoreLookup';
import FeeCurve from './components/FeeCurve';
import SwapPanel from './components/SwapPanel';
import EventFeed from './components/EventFeed';
import TaskDashboard from './components/TaskDashboard';
import ArchitectureDiagram from './components/ArchitectureDiagram';
import './App.css';

function App() {
  const { address, isConnected } = useAccount();
  const { connect } = useConnect();
  const { disconnect } = useDisconnect();
  const [activeTab, setActiveTab] = useState<'dashboard' | 'swap' | 'tasks'>('dashboard');

  const getInitialTheme = (): 'dark' | 'light' => {
    try {
      const saved = localStorage.getItem('gs-theme');
      if (saved === 'light' || saved === 'dark') return saved;
    } catch {}
    return 'dark';
  };

  const [theme, setTheme] = useState<'dark' | 'light'>(getInitialTheme);

  useEffect(() => {
    document.documentElement.setAttribute('data-theme', theme);
    try { localStorage.setItem('gs-theme', theme); } catch {}
  }, [theme]);

  const toggleTheme = useCallback(() => {
    setTheme(prev => prev === 'dark' ? 'light' : 'dark');
  }, []);

  const handleConnect = () => {
    connect({ connector: injected() });
  };

  return (
    <div className="app">
      <Header
        address={address}
        isConnected={isConnected}
        onConnect={handleConnect}
        onDisconnect={disconnect}
        theme={theme}
        onToggleTheme={toggleTheme}
      />

      <nav className="tab-nav">
        <button
          className={`tab-btn ${activeTab === 'dashboard' ? 'active' : ''}`}
          onClick={() => setActiveTab('dashboard')}
        >
          Dashboard
        </button>
        <button
          className={`tab-btn ${activeTab === 'swap' ? 'active' : ''}`}
          onClick={() => setActiveTab('swap')}
        >
          Swap
        </button>
        <button
          className={`tab-btn ${activeTab === 'tasks' ? 'active' : ''}`}
          onClick={() => setActiveTab('tasks')}
        >
          BLS Tasks
        </button>
      </nav>

      <main className="main-content">
        {activeTab === 'dashboard' && (
          <>
            <div className="grid-2col">
              <ScoreLookup connectedAddress={address} />
              <FeeCurve />
            </div>
            <ArchitectureDiagram />
            <EventFeed />
          </>
        )}

        {activeTab === 'swap' && (
          <SwapPanel isConnected={isConnected} address={address} />
        )}

        {activeTab === 'tasks' && (
          <TaskDashboard />
        )}
      </main>

      <footer className="footer">
        <p>GradientShield — Uniswap v4 Anti-MEV Hook powered by EigenLayer AVS</p>
        <p className="footer-sub">Project HK-UHI10-1050 | EigenLayer Hookathon</p>
      </footer>
    </div>
  );
}

export default App;
