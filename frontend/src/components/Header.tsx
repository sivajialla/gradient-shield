import './Header.css';

interface HeaderProps {
  address?: `0x${string}`;
  isConnected: boolean;
  onConnect: () => void;
  onDisconnect: () => void;
  theme: 'dark' | 'light';
  onToggleTheme: () => void;
}

export default function Header({ address, isConnected, onConnect, onDisconnect, theme, onToggleTheme }: HeaderProps) {
  const truncate = (addr: string) => `${addr.slice(0, 6)}...${addr.slice(-4)}`;

  return (
    <header className="header">
      <div className="header-left">
        <div className="logo">
          <span className="logo-text">GradientShield</span>
        </div>
        <span className="network-badge">Sepolia</span>
      </div>

      <div className="header-right">
        <button
          className="theme-toggle"
          onClick={onToggleTheme}
          aria-label={`Switch to ${theme === 'dark' ? 'light' : 'dark'} mode`}
          title={`Switch to ${theme === 'dark' ? 'light' : 'dark'} mode`}
        >
          {theme === 'dark' ? '☀️' : '🌙'}
        </button>
        {isConnected && address ? (
          <div className="wallet-info">
            <span className="wallet-dot" />
            <span className="wallet-address">{truncate(address)}</span>
            <button className="btn btn-outline btn-sm" onClick={onDisconnect}>
              Disconnect
            </button>
          </div>
        ) : (
          <button className="btn btn-primary" onClick={onConnect}>
            Connect Wallet
          </button>
        )}
      </div>
    </header>
  );
}
