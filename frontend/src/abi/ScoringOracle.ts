export const ScoringOracleABI = [
  {
    "type": "constructor",
    "inputs": [
      {
        "name": "_avs",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "DECAY_PER_DAY",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint16",
        "internalType": "uint16"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "MAX_SCORE",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "uint16",
        "internalType": "uint16"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "avs",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "bumpScore",
    "inputs": [
      {
        "name": "subject",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "delta",
        "type": "uint16",
        "internalType": "uint16"
      }
    ],
    "outputs": [
      {
        "name": "newScore",
        "type": "uint16",
        "internalType": "uint16"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "getScore",
    "inputs": [
      {
        "name": "subject",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint16",
        "internalType": "uint16"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "owner",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "address"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "rawRecord",
    "inputs": [
      {
        "name": "subject",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "tuple",
        "internalType": "struct ScoringOracle.ScoreRecord",
        "components": [
          {
            "name": "score",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "lastUpdated",
            "type": "uint40",
            "internalType": "uint40"
          }
        ]
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "setAvs",
    "inputs": [
      {
        "name": "newAvs",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "setScore",
    "inputs": [
      {
        "name": "subject",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "newScore",
        "type": "uint16",
        "internalType": "uint16"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "transferOwnership",
    "inputs": [
      {
        "name": "newOwner",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "event",
    "name": "AvsUpdated",
    "inputs": [
      {
        "name": "oldAvs",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "newAvs",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "ScoreUpdated",
    "inputs": [
      {
        "name": "subject",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "oldScore",
        "type": "uint16",
        "indexed": false,
        "internalType": "uint16"
      },
      {
        "name": "newScore",
        "type": "uint16",
        "indexed": false,
        "internalType": "uint16"
      },
      {
        "name": "writer",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      }
    ],
    "anonymous": false
  },
  {
    "type": "error",
    "name": "NotAvs",
    "inputs": []
  },
  {
    "type": "error",
    "name": "NotOwner",
    "inputs": []
  },
  {
    "type": "error",
    "name": "ScoreOutOfRange",
    "inputs": [
      {
        "name": "score",
        "type": "uint16",
        "internalType": "uint16"
      }
    ]
  },
  {
    "type": "error",
    "name": "ZeroAddress",
    "inputs": []
  }
] as const;
