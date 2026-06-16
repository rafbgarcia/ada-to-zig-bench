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
  Tooltip,
  XAxis,
  YAxis,
} from 'recharts';
import {
  fetchRuns,
  loadRun,
  metricGroups,
  phaseColors,
  phaseLabels,
} from './data.js';
import {
  formatCompact, formatSeriesValue
} from './format.js';

const chartMargin = { top: 16, right: 14, bottom: 4, left: 0 };

const runAccents = ['#0f766e', '#2563eb', '#7c3aed', '#b42318', '#0891b2', '#d97706', '#be185d', '#15803d'];
const runNameCollator = new Intl.Collator(undefined, { numeric: true, sensitivity: 'base' });

function accentFor(index) {
  return runAccents[index % runAccents.length];
}

function runSortLabel(run) {
  const meta = run.metadata ?? {};
  return meta.server ?? run.id ?? '';
}

function sortRunsAlphabetically(runs) {
  return [...runs].sort((left, right) => (
    runNameCollator.compare(runSortLabel(left), runSortLabel(right))
    || runNameCollator.compare(left.id ?? '', right.id ?? '')
  ));
}

export default function App() {
  const [runs, setRuns] = useState([]);
  const [selectedIDs, setSelectedIDs] = useState([]);
  const [loadedByID, setLoadedByID] = useState({});
  const [pendingIDs, setPendingIDs] = useState({});
  const [errorsByID, setErrorsByID] = useState({});
  const [booting, setBooting] = useState(true);
  const [bootError, setBootError] = useState('');
  const loadingIDsRef = useRef(new Set());

  useEffect(() => {
    let cancelled = false;

    async function boot() {
      try {
        const nextRuns = sortRunsAlphabetically(await fetchRuns());
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

  const orderedSelection = runs.filter((run) => selectedIDs.includes(run.id));

  const activePhases = useMemo(() => {
    const seen = new Set();
    for (const run of orderedSelection) {
      const loaded = loadedByID[run.id];
      for (const phase of loaded?.phases ?? []) seen.add(phase.name);
    }
    return Object.keys(phaseColors).filter((name) => seen.has(name));
  }, [orderedSelection, loadedByID]);

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
        onToggleRun={toggleRun}
      />

      <main className="board">
        {bootError ? <ErrorBanner message={bootError} /> : null}

        {activePhases.length > 0 ? <PhaseLegend phases={activePhases} /> : null}

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
                groups={metricGroups}
              />
            ))}
          </div>
        )}
      </main>
    </div>
  );
}

function PhaseLegend({ phases }) {
  return (
    <div className="phase-legend">
      <span className="phase-legend-label">Phases</span>
      {phases.map((name) => (
        <span className="phase-legend-item" key={name}>
          <i style={{ backgroundColor: phaseColors[name] ?? phaseColors.unknown }} />
          {phaseLabels[name] ?? name}
        </span>
      ))}
    </div>
  );
}

function Sidebar({
  runs,
  selectedIDs,
  pendingIDs,
  accentByID,
  booting,
  onToggleRun,
}) {
  return (
    <aside className="sidebar">
      <div className="sidebar-brand">
        <h1>Ada to Zig bench</h1>
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
                    <span className="run-check">
                      {selected ? <Check size={9} strokeWidth={3} /> : null}
                    </span>
                    <span className="run-info">
                      {meta.runtime ?? meta.language ?? meta.server ?? run.id}
                    </span>
                    {pendingIDs[run.id] ? <Loader2 size={14} className="spin" /> : null}
                  </button>
                </li>
              );
            })
          )}
        </ul>
      </div>
    </aside>
  );
}

function BenchColumn({ run, index = 0, accent, loaded, loading, error, groups }) {
  const meta = loaded?.metadata ?? run.metadata ?? {};
  const status = runStatus(loaded);

  return (
    <section className="bench-column" style={{ '--accent': accent, animationDelay: `${index * 70}ms` }}>
      <header className="column-header">
        <div className="column-title">
          <div>
            <strong>{meta.runtime ?? meta.language ?? meta.server ?? run.id}</strong>
          </div>
        </div>
        {status ? <RunStatusBadge status={status} /> : null}
      </header>

      <div className="column-body">
        {error ? (
          <div className="column-state error"><AlertTriangle size={16} /> {error}</div>
        ) : loading || !loaded ? (
          <div className="column-state"><Loader2 size={16} className="spin" /> Loading run…</div>
        ) : (
          <>
            {status?.kind === 'failed' || status?.kind === 'warning' ? <RunFailureSummary loaded={loaded} status={status} /> : null}
            <div className="column-charts">
              {groups.map((group) => (
                <MetricChart
                  key={group.id}
                  group={group}
                  loaded={loaded}
                  phases={loaded.phases ?? []}
                />
              ))}
            </div>
          </>
        )}
      </div>
    </section>
  );
}

function RunStatusBadge({ status }) {
  return <span className={`run-status run-status-${status.kind}`}>{status.label}</span>;
}

function RunFailureSummary({ loaded, status }) {
  const summary = loaded.summary ?? {};
  const details = [
    summary.total_errors ? `${formatCompact(summary.total_errors)} errors` : null,
    summary.total_dispatch_misses ? `${formatCompact(summary.total_dispatch_misses)} missed slots` : null,
    summary.total_connection_retries ? `${formatCompact(summary.total_connection_retries)} retries` : null,
    summary.total_connection_failures ? `${formatCompact(summary.total_connection_failures)} failed slots` : null,
  ].filter(Boolean);

  return (
    <div className="run-failure" role="status">
      <AlertTriangle size={15} />
      <span>{details.length > 0 ? details.join(' · ') : status.label}</span>
    </div>
  );
}

function runStatus(loaded) {
  if (!loaded?.summary) return null;
  const summary = loaded.summary;
  if (summary.success === true) {
    return (summary.total_dispatch_misses ?? 0) > 0
      ? { kind: 'warning', label: 'Saturated' }
      : { kind: 'success', label: 'Complete' };
  }
  if (summary.complete === true) return { kind: 'failed', label: 'Invalid' };
  if (summary.complete === false) return { kind: 'failed', label: 'Incomplete' };
  return { kind: 'failed', label: 'Failed' };
}

function MetricChart({ group, loaded, phases }) {
  const data = loaded?.timeline ?? [];
  const maxElapsed = loaded?.maxElapsed ?? 1;
  const series = group.series;
  const [surfaceRef, surfaceSize] = useElementSize();
  const chartReady = surfaceSize.width > 0 && surfaceSize.height > 0;
  const hasValues = data.some((row) => series.some((entry) => row[entry.key] != null));

  return (
    <article className={`chart-card chart-card-${group.id}`}>
      <div className="chart-header">
        <h3>{group.title}</h3>
        {group.unit ? <span className="chart-unit">{group.unit}</span> : null}
      </div>

      <div className="chart-surface" ref={surfaceRef}>
        {data.length === 0 || !chartReady || !hasValues ? (
          <div className="chart-placeholder">No data</div>
        ) : (
          <LineChart
            width={surfaceSize.width}
            height={surfaceSize.height}
            data={data}
            margin={chartMargin}
          >
            <CartesianGrid stroke="#262a31" strokeDasharray="3 4" vertical={false} />
            {phases.map((phase) => (
              <ReferenceArea
                key={`${group.id}-${phase.name}-${phase.stageIndex}-${phase.start}`}
                x1={phase.start}
                x2={phase.end}
                yAxisId="left"
                fill={phaseColors[phase.name] ?? phaseColors.unknown}
                fillOpacity={0.14}
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
              stroke="#6b7180"
              fontSize={11}
              tick={{ fill: '#8b909b' }}
            />
            <YAxis
              yAxisId="left"
              domain={group.yDomain}
              allowDataOverflow={Boolean(group.yDomain)}
              tickLine={false}
              axisLine={false}
              width={40}
              stroke="#6b7180"
              fontSize={11}
              tick={{ fill: '#8b909b' }}
              tickFormatter={formatCompact}
            />
            {group.dualAxis ? (
              <YAxis
                yAxisId="right"
                orientation="right"
                tickLine={false}
                axisLine={false}
                width={36}
                stroke="#d98a4f"
                fontSize={11}
                tick={{ fill: '#d98a4f' }}
                tickFormatter={formatCompact}
              />
            ) : null}
            <Tooltip content={<ChartTooltip group={group} />} cursor={{ stroke: '#3a3f48', strokeWidth: 1 }} />
            <Legend verticalAlign="top" height={28} iconType="circle" wrapperStyle={{ fontSize: 11, paddingBottom: 4, color: '#aeb3bd' }} />
            {series.map((series) => (
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
        <span>{row?.phase ?? 'setup'}</span>
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
