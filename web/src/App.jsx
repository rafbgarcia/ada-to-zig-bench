import { useEffect, useMemo, useRef, useState } from 'react';
import {
  AlertTriangle,
  BarChart3,
  Check,
  Loader2,
  Server,
} from 'lucide-react';
import {
  CartesianGrid,
  Legend,
  Line,
  LineChart,
  ReferenceArea,
  ReferenceLine,
  Tooltip,
  XAxis,
  YAxis,
} from 'recharts';
import {
  fetchRuns,
  loadRun,
  metricGroups,
  phaseColors,
  significantRuntimeEvents,
} from './data.js';
import {
  formatCompact,
  formatFixed,
  formatNumber,
  formatRatio,
  formatRate,
  formatRunDate,
  formatSeriesValue,
} from './format.js';

const chartMargin = { top: 16, right: 14, bottom: 4, left: 0 };

const runAccents = ['#0f766e', '#2563eb', '#7c3aed', '#b42318', '#0891b2', '#d97706', '#be185d', '#15803d'];

function accentFor(index) {
  return runAccents[index % runAccents.length];
}

export default function App() {
  const [runs, setRuns] = useState([]);
  const [selectedIDs, setSelectedIDs] = useState([]);
  const [loadedByID, setLoadedByID] = useState({});
  const [pendingIDs, setPendingIDs] = useState({});
  const [errorsByID, setErrorsByID] = useState({});
  const [showRuntimeEvents, setShowRuntimeEvents] = useState(true);
  const [showLatency, setShowLatency] = useState(false);
  const [booting, setBooting] = useState(true);
  const [bootError, setBootError] = useState('');
  const loadingIDsRef = useRef(new Set());

  useEffect(() => {
    let cancelled = false;

    async function boot() {
      try {
        const nextRuns = await fetchRuns();
        if (cancelled) return;
        setRuns(nextRuns);
        if (nextRuns[0]) setSelectedIDs([nextRuns[0].id]);
      } catch (nextError) {
        if (!cancelled) setBootError(nextError.message);
      } finally {
        if (!cancelled) setBooting(false);
      }
    }

    boot();
    return () => {
      cancelled = true;
    };
  }, []);

  useEffect(() => {
    const toLoad = selectedIDs.filter((id) => !loadedByID[id] && !loadingIDsRef.current.has(id));
    if (toLoad.length === 0) return undefined;

    for (const id of toLoad) loadingIDsRef.current.add(id);

    setPendingIDs((current) => {
      const next = { ...current };
      for (const id of toLoad) next[id] = true;
      return next;
    });

    for (const id of toLoad) {
      loadRun(id)
        .then((run) => {
          setLoadedByID((current) => ({ ...current, [id]: run }));
          setErrorsByID((current) => {
            if (!current[id]) return current;
            const next = { ...current };
            delete next[id];
            return next;
          });
        })
        .catch((nextError) => {
          setErrorsByID((current) => ({ ...current, [id]: nextError.message }));
        })
        .finally(() => {
          loadingIDsRef.current.delete(id);
          setPendingIDs((current) => {
            const next = { ...current };
            delete next[id];
            return next;
          });
        });
    }

    return undefined;
  }, [selectedIDs, loadedByID]);

  const accentByID = useMemo(() => {
    const map = {};
    runs.forEach((run, index) => {
      map[run.id] = accentFor(index);
    });
    return map;
  }, [runs]);

  const visibleMetricGroups = showLatency ? metricGroups : metricGroups.filter((group) => !group.secondary);
  const orderedSelection = runs.filter((run) => selectedIDs.includes(run.id));

  function toggleRun(id) {
    setSelectedIDs((current) =>
      current.includes(id) ? current.filter((value) => value !== id) : [...current, id],
    );
  }

  if (!booting && runs.length === 0) {
    return <EmptyState message={bootError} />;
  }

  return (
    <div className="app">
      <Sidebar
        runs={runs}
        selectedIDs={selectedIDs}
        pendingIDs={pendingIDs}
        accentByID={accentByID}
        booting={booting}
        showRuntimeEvents={showRuntimeEvents}
        showLatency={showLatency}
        onToggleRun={toggleRun}
        onToggleRuntimeEvents={setShowRuntimeEvents}
        onToggleLatency={setShowLatency}
      />

      <main className="board">
        {bootError ? <ErrorBanner message={bootError} /> : null}

        {orderedSelection.length === 0 ? (
          <div className="board-empty">
            <BarChart3 size={26} />
            <h2>Select a benchmark</h2>
            <p>Pick one or more servers from the sidebar to compare them side by side.</p>
          </div>
        ) : (
          <div className="columns">
            {orderedSelection.map((run, index) => (
              <BenchColumn
                key={run.id}
                run={run}
                index={index}
                accent={accentByID[run.id]}
                loaded={loadedByID[run.id]}
                loading={Boolean(pendingIDs[run.id])}
                error={errorsByID[run.id]}
                groups={visibleMetricGroups}
                showRuntimeEvents={showRuntimeEvents}
              />
            ))}
          </div>
        )}
      </main>
    </div>
  );
}

function Sidebar({
  runs,
  selectedIDs,
  pendingIDs,
  accentByID,
  booting,
  showRuntimeEvents,
  showLatency,
  onToggleRun,
  onToggleRuntimeEvents,
  onToggleLatency,
}) {
  return (
    <aside className="sidebar">
      <div className="sidebar-brand">
        <div className="eyebrow"><BarChart3 size={15} /> Server Benchmark</div>
        <h1>Connection + JSON</h1>
        <p>Compare resource cost for long-lived HTTP connections with small JSON work.</p>
      </div>

      <div className="sidebar-section">
        <span className="sidebar-label">Benchmarks</span>
        <ul className="run-list">
          {booting && runs.length === 0 ? (
            <li className="run-skeleton">Loading…</li>
          ) : (
            runs.map((run) => {
              const selected = selectedIDs.includes(run.id);
              const meta = run.metadata ?? {};
              return (
                <li key={run.id}>
                  <button
                    type="button"
                    className={`run-item${selected ? ' is-selected' : ''}`}
                    aria-pressed={selected}
                    onClick={() => onToggleRun(run.id)}
                  >
                    <span className="run-check" style={selected ? { background: accentByID[run.id], borderColor: accentByID[run.id] } : undefined}>
                      {selected ? <Check size={12} strokeWidth={3} /> : null}
                    </span>
                    <span className="run-info">
                      <strong>{meta.server ?? run.id}</strong>
                      <small>{meta.runtime ?? meta.language ?? 'runtime'}</small>
                    </span>
                    {pendingIDs[run.id] ? <Loader2 size={14} className="spin" /> : null}
                  </button>
                </li>
              );
            })
          )}
        </ul>
      </div>

      <div className="sidebar-section">
        <span className="sidebar-label">Overlays</span>
        <label className="switch">
          <input type="checkbox" checked={showRuntimeEvents} onChange={(event) => onToggleRuntimeEvents(event.target.checked)} />
          <span className="switch-track" aria-hidden="true"><span /></span>
          <span>Runtime events</span>
        </label>
        <label className="switch">
          <input type="checkbox" checked={showLatency} onChange={(event) => onToggleLatency(event.target.checked)} />
          <span className="switch-track" aria-hidden="true"><span /></span>
          <span>Latency charts</span>
        </label>
      </div>
    </aside>
  );
}

function BenchColumn({ run, index = 0, accent, loaded, loading, error, groups, showRuntimeEvents }) {
  const meta = loaded?.metadata ?? run.metadata ?? {};
  const runtimeMarkers = useMemo(
    () => (loaded ? significantRuntimeEvents(loaded.runtimeEvents) : []),
    [loaded],
  );

  return (
    <section className="bench-column" style={{ '--accent': accent, animationDelay: `${index * 70}ms` }}>
      <header className="column-header">
        <div className="column-title">
          <span className="column-dot" />
          <div>
            <strong>{meta.server ?? run.id}</strong>
            <small>{meta.runtime ?? meta.language ?? 'runtime'}</small>
          </div>
        </div>
        <dl className="column-meta">
          <div>
            <dt>Target RPS</dt>
            <dd>{meta.target_requests_per_second ? formatRate(meta.target_requests_per_second) : '--'}</dd>
          </div>
          <div>
            <dt>Connections</dt>
            <dd>{formatTargets(meta.connection_targets)}</dd>
          </div>
          <div>
            <dt>Payload</dt>
            <dd>{meta.payload_bytes ? `${formatNumber(meta.payload_bytes)} B` : '--'}</dd>
          </div>
          <div>
            <dt>Started</dt>
            <dd>{meta.started_at ? formatRunDate(meta.started_at) : '--'}</dd>
          </div>
        </dl>
      </header>

      {error ? (
        <div className="column-state error"><AlertTriangle size={16} /> {error}</div>
      ) : loading || !loaded ? (
        <div className="column-state"><Loader2 size={16} className="spin" /> Loading run…</div>
      ) : (
        <>
          <RunSummary loaded={loaded} />
          <div className="column-charts">
            {groups.map((group) => (
              <MetricChart
                key={group.id}
                group={group}
                loaded={loaded}
                phases={loaded.phases ?? []}
                showRuntimeEvents={showRuntimeEvents}
                runtimeMarkers={runtimeMarkers}
              />
            ))}
          </div>
        </>
      )}
    </section>
  );
}

function RunSummary({ loaded }) {
  const stats = useMemo(() => summarizeRun(loaded), [loaded]);

  return (
    <div className="summary-grid">
      <SummaryItem label="Target" value={stats.targetStatus} tone={stats.success ? undefined : 'bad'} />
      <SummaryItem label="Peak conns" value={`${formatCompact(stats.peakConnections)} / ${formatCompact(stats.targetConnections)}`} tone={stats.success ? undefined : 'warn'} />
      <SummaryItem label="Peak RSS" value={`${formatFixed(stats.peakRssMb, 1)} MB`} />
      <SummaryItem label="RSS / 10k conns" value={`${formatFixed(stats.peakRssPer10k, 1)} MB`} />
      <SummaryItem label="Avg CPU traffic" value={`${formatFixed(stats.avgTrafficCpu, 1)}%`} />
      <SummaryItem label="FDs / conn" value={formatRatio(stats.peakFdsPerConnection, 2)} />
      <SummaryItem label="Errors" value={formatNumber(stats.totalErrors)} tone={stats.totalErrors > 0 ? 'bad' : undefined} />
      <SummaryItem label="Dispatch misses" value={formatNumber(stats.totalDispatchMisses)} tone={stats.totalDispatchMisses > 0 ? 'warn' : undefined} />
    </div>
  );
}

function SummaryItem({ label, value, tone }) {
  return (
    <div className={`summary-item${tone ? ` summary-${tone}` : ''}`}>
      <span>{label}</span>
      <strong>{value}</strong>
    </div>
  );
}

function MetricChart({ group, loaded, phases, showRuntimeEvents, runtimeMarkers }) {
  const data = loaded?.timeline ?? [];
  const maxElapsed = loaded?.maxElapsed ?? 1;
  const [surfaceRef, surfaceSize] = useElementSize();
  const chartReady = surfaceSize.width > 0 && surfaceSize.height > 0;

  return (
    <article className={`chart-card chart-card-${group.id}`}>
      <div className="chart-header">
        <h3>{group.title}</h3>
        {group.unit ? <span className="chart-unit">{group.unit}</span> : null}
      </div>

      <div className="chart-surface" ref={surfaceRef}>
        {data.length === 0 || !chartReady ? (
          <div className="chart-placeholder">No data</div>
        ) : (
          <LineChart
            width={surfaceSize.width}
            height={surfaceSize.height}
            data={data}
            margin={chartMargin}
          >
            <CartesianGrid stroke="#eef1f5" strokeDasharray="3 4" vertical={false} />
            {phases.map((phase) => (
              <ReferenceArea
                key={`${group.id}-${phase.name}-${phase.stageIndex}-${phase.start}`}
                x1={phase.start}
                x2={phase.end}
                yAxisId="left"
                fill={phaseColors[phase.name] ?? phaseColors.unknown}
                fillOpacity={0.46}
                strokeOpacity={0}
              />
            ))}
            <XAxis
              dataKey="second"
              type="number"
              domain={[0, Math.max(1, maxElapsed)]}
              tickLine={false}
              axisLine={false}
              minTickGap={26}
              tickFormatter={(value) => `${Math.round(value)}s`}
              stroke="#98a2b3"
              fontSize={11}
            />
            <YAxis
              yAxisId="left"
              tickLine={false}
              axisLine={false}
              width={40}
              stroke="#98a2b3"
              fontSize={11}
              tickFormatter={formatCompact}
            />
            {group.dualAxis ? (
              <YAxis
                yAxisId="right"
                orientation="right"
                tickLine={false}
                axisLine={false}
                width={36}
                stroke="#c2410c"
                fontSize={11}
                tickFormatter={formatCompact}
              />
            ) : null}
            <Tooltip content={<ChartTooltip group={group} />} cursor={{ stroke: '#cbd2dc', strokeWidth: 1 }} />
            <Legend verticalAlign="top" height={28} iconType="circle" wrapperStyle={{ fontSize: 11, paddingBottom: 4 }} />
            {group.series.map((series) => (
              <Line
                key={series.key}
                yAxisId={series.axis === 'right' ? 'right' : 'left'}
                type="monotone"
                dataKey={series.key}
                name={series.label}
                stroke={series.color}
                strokeWidth={2}
                dot={false}
                connectNulls
                activeDot={{ r: 3.5, strokeWidth: 0 }}
                isAnimationActive={false}
              />
            ))}
            {showRuntimeEvents ? runtimeMarkers.map((event, index) => (
              <ReferenceLine
                key={`${group.id}-runtime-${event.second}-${index}`}
                x={event.second}
                yAxisId="left"
                stroke={event.kind === 'major' ? '#b42318' : '#98a2b3'}
                strokeDasharray={event.kind === 'major' ? undefined : '3 3'}
                strokeOpacity={0.6}
              />
            )) : null}
          </LineChart>
        )}
      </div>
    </article>
  );
}

function EmptyState({ message }) {
  return (
    <div className="empty-shell">
      <section className="empty-state">
        <Server size={28} />
        <h1>HTTP JSON Server Activity</h1>
        {message ? (
          <p className="empty-error"><AlertTriangle size={16} /> {message}</p>
        ) : (
          <p>Generate a run with <code>./scripts/run-local.sh</code>, then rebuild the web app to inspect the dataset.</p>
        )}
      </section>
    </div>
  );
}

function ErrorBanner({ message }) {
  return (
    <div className="error-banner" role="alert">
      <AlertTriangle size={18} />
      <span>{message}</span>
    </div>
  );
}

function useElementSize() {
  const ref = useRef(null);
  const [size, setSize] = useState({ width: 0, height: 0 });

  useEffect(() => {
    const node = ref.current;
    if (!node) return undefined;

    const updateSize = () => {
      const rect = node.getBoundingClientRect();
      const width = Math.floor(rect.width);
      const height = Math.floor(rect.height);
      setSize((current) => (current.width === width && current.height === height ? current : { width, height }));
    };

    updateSize();
    const observer = new ResizeObserver(updateSize);
    observer.observe(node);
    return () => observer.disconnect();
  }, []);

  return [ref, size];
}

function ChartTooltip({ active, payload, label, group }) {
  if (!active || !payload?.length) return null;
  const row = payload[0]?.payload;

  return (
    <div className="chart-tooltip">
      <div className="tooltip-title">
        <strong>{Math.round(Number(label) || 0)}s</strong>
        <span>{row?.phase ?? 'idle'}</span>
      </div>
      {payload.map((item) => {
        const series = group.series.find((entry) => entry.key === item.dataKey);
        return (
          <div className="tooltip-row" key={item.dataKey}>
            <span><i style={{ backgroundColor: item.color }} /> {item.name}</span>
            <strong>{formatSeriesValue(item.value, series?.unit ?? group.unit)}</strong>
          </div>
        );
      })}
    </div>
  );
}

function formatTargets(values) {
  if (!Array.isArray(values) || values.length === 0) return '--';
  return values.map((value) => formatCompact(value)).join(' → ');
}

function summarizeRun(loaded) {
  const timeline = loaded?.timeline ?? [];
  const summary = loaded?.summary ?? {};
  const connectionTargets = Array.isArray(summary.connection_targets)
    ? summary.connection_targets.map(Number).filter(Number.isFinite)
    : [];
  const targetConnections = Number(summary.connections ?? (connectionTargets.length ? Math.max(...connectionTargets) : 0));
  const peakConnections = Number(summary.peak_active_connections ?? maxOf(timeline, 'loadgenConnections'));
  const success = Boolean(summary.success ?? (targetConnections > 0 && peakConnections >= targetConnections));
  const trafficRows = timeline.filter((row) => row.phase === 'traffic' || row.phase === 'payload_sweep');
  const peakRssMb = maxOf(timeline, 'rssMb');
  const peakRssPer10k = maxOf(timeline, 'rssMbPer10kConnections');
  const peakFdsPerConnection = maxOf(timeline, 'fdsPerConnection');
  const avgTrafficCpu = averageOf(trafficRows, 'cpuPercent');
  return {
    targetStatus: success ? 'Hit' : 'Miss',
    success,
    targetConnections,
    peakConnections,
    peakRssMb,
    peakRssPer10k,
    peakFdsPerConnection,
    avgTrafficCpu,
    totalErrors: Number(summary.total_errors ?? 0),
    totalDispatchMisses: Number(summary.total_dispatch_misses ?? 0),
  };
}

function maxOf(rows, key) {
  const values = rows.map((row) => Number(row[key])).filter(Number.isFinite);
  return values.length ? Math.max(...values) : 0;
}

function averageOf(rows, key) {
  const values = rows.map((row) => Number(row[key])).filter(Number.isFinite);
  if (values.length === 0) return 0;
  return values.reduce((total, value) => total + value, 0) / values.length;
}
