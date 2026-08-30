import './ArchitectureDiagram.css';

export default function ArchitectureDiagram() {
  return (
    <div className="card architecture">
      <div className="card-title">Architecture</div>

      <div className="arch-diagram">
        <div className="arch-section on-chain">
          <div className="section-label">ON-CHAIN</div>

          <div className="arch-row">
            <div className="arch-box swapper">
              <div className="box-icon">&#128100;</div>
              <div className="box-title">Swapper</div>
              <div className="box-sub">swap()</div>
            </div>
            <div className="arch-arrow">&#8594;</div>
            <div className="arch-box pool-manager">
              <div className="box-icon">&#127974;</div>
              <div className="box-title">PoolManager</div>
              <div className="box-sub">Uniswap v4</div>
            </div>
            <div className="arch-arrow">&#8594;</div>
            <div className="arch-box hook">
              <div className="box-icon">&#128737;</div>
              <div className="box-title">GradientShieldHook</div>
              <div className="box-sub">beforeSwap | ERC6909 | unlockCallback</div>
              <div className="hook-features">
                <span className="feature-tag">Sandwich Detection</span>
                <span className="feature-tag">JIT Detection</span>
                <span className="feature-tag">Fee Curve</span>
                <span className="feature-tag">Transient Storage</span>
              </div>
            </div>
          </div>

          <div className="arch-row lower-row">
            <div className="arch-box oracle">
              <div className="box-icon">&#128202;</div>
              <div className="box-title">ScoringOracle</div>
              <div className="box-sub">Score + Decay (5 pts/day)</div>
            </div>
            <div className="arch-arrow-bi">&#8596;</div>
            <div className="arch-box task-mgr">
              <div className="box-icon">&#9989;</div>
              <div className="box-title">TaskManager</div>
              <div className="box-sub">BLS Signature Checker</div>
            </div>
            <div className="arch-arrow-bi">&#8596;</div>
            <div className="arch-box service-mgr">
              <div className="box-icon">&#128279;</div>
              <div className="box-title">ServiceManager</div>
              <div className="box-sub">EigenLayer AVS</div>
            </div>
          </div>
        </div>

        <div className="arch-connector">
          <div className="connector-line" />
          <div className="connector-labels">
            <span>BLS partial sigs &#8593;</span>
            <span>&#8595; respondToScoreTask()</span>
          </div>
          <div className="connector-line" />
        </div>

        <div className="arch-section off-chain">
          <div className="section-label">OFF-CHAIN</div>
          <div className="arch-row">
            <div className="arch-box operator">
              <div className="box-icon">&#128187;</div>
              <div className="box-title">Operator 1</div>
              <div className="box-sub">BLS Key + Score</div>
            </div>
            <div className="arch-box operator">
              <div className="box-icon">&#128187;</div>
              <div className="box-title">Operator 2</div>
              <div className="box-sub">BLS Key + Score</div>
            </div>
            <div className="arch-box operator">
              <div className="box-icon">&#128187;</div>
              <div className="box-title">Operator N</div>
              <div className="box-sub">BLS Key + Score</div>
            </div>
            <div className="arch-arrow">&#8594;</div>
            <div className="arch-box aggregator">
              <div className="box-icon">&#128290;</div>
              <div className="box-title">Aggregator</div>
              <div className="box-sub">BLS Aggregate + Submit</div>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
