import { http, createConfig } from 'wagmi';
import { sepolia } from 'wagmi/chains';

export const config = createConfig({
  chains: [sepolia],
  transports: {
    [sepolia.id]: http(),
  },
});

// Contract addresses — update after deployment
export const CONTRACTS = {
  scoringOracle: (import.meta.env.VITE_ORACLE_ADDRESS || '0x0000000000000000000000000000000000000000') as `0x${string}`,
  hook: (import.meta.env.VITE_HOOK_ADDRESS || '0x0000000000000000000000000000000000000000') as `0x${string}`,
  taskManager: (import.meta.env.VITE_TASK_MANAGER_ADDRESS || '0x0000000000000000000000000000000000000000') as `0x${string}`,
};
