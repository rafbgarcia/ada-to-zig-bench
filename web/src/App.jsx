import { useEffect, useMemo, useRef, useState } from 'react';
import {
  AlertTriangle,
  BarChart3,
  MousePointer2,
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
  nearestSample,
  phaseColors,
  recentEvents,
  significantRuntimeEvents,
} from './data.js';
import {
  formatCompact,
  formatDuration,
  formatNumber,
  formatRate,
  formatRunDate,
  formatSeriesValue,
} from './format.js';

const chartMargin = { top: 18, right: 18, bottom: 8, left: 4 };

export default function App() {
  const [runs, setRuns] = useState([]);
  const [selectedRunID, setSelectedRunID] = useState('');
  const [loaded, setLoaded] = useState(null);
  const [frame, setFrame] = useState(0);
  const [showRuntimeEvents, setShowRuntimeEvents] = useState(true);
  const [showLatency, setShowLatency] = useState(false);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');

  useEffect(() => {
    let cancelled = false;

    async function boot() {
      try {
        const nextRuns = await fetchRuns();
        if (cancelled) return;
        setRuns(nextRuns);
        setSelectedRunID(nextRuns[0]?.id ?? '');
      } catch (nextError) {
        if (!cancelled) setError(nextError.message);
      } finally {
        if (!cancelled) setLoading(false);
      }
    }

    boot();
    return () => {
      cancelled = true;
    };
  }, []);

  useEffect(() => {
    if (!selectedRunID) return undefined;

    let cancelled = false;
    setLoading(true);
    setError('');

    async function hydrateRun() {
      try {
        const nextRun = await loadRun(selectedRunID);
        if (cancelled) return;
        setLoaded(nextRun);
        setFrame(0);
      } catch (nextError) {
        if (!cancelled) {
          setLoaded(null);
          setError(nextError.message);
        }
      } finally {
        if (!cancelled) setLoading(false);
      }
    }

    hydrateRun();
    return () => {
      cancelled = true;
    };
  }, [selectedRunID]);

  const current = useMemo(() => {
    if (!loaded) return null;
    const row = loaded.timeline[Math.min(frame, loaded.timeline.length - 1)] ?? loaded.timeline[0];
    return {
      row,
      activity: nearestSample(loaded.activityMetrics, frame),
      server: nearestSample(loaded.serverMetrics, frame),
      loadgen: nearestSample(loaded.loadgenMetrics, frame),
      runtime: nearestSample(loaded.runtimeMetrics, frame),
    };
  }, [frame, loaded]);

  const runtimeMarkers = useMemo(() => (loaded ? significantRuntimeEvents(loaded.runtimeEvents) : []), [loaded]);
  const eventRows = useMemo(() => recentEvents(loaded, frame), [loaded, frame]);
  const visibleMetricGroups = showLatency ? metricGroups : metricGroups.filter((group) => !group.secondary);

  function handleFrameChange(value) {
    if (!loaded) return;
    const nextFrame = Math.min(loaded.maxElapsed, Math.max(0, Math.round(Number(value) || 0)));
    setFrame(nextFrame);
  }

  if (!loading && runs.length === 0) {
    return <EmptyState />;
  }

  return (
    <main className="shell">
      <header className="topbar">
        <div className="title-block">
          <div className="eyebrow"><BarChart3 size={16} /> Server Benchmark</div>
          <h1>HTTP JSON Server Activity</h1>
          <p>{loaded ? subtitleFor(loaded.metadata) : 'Load a benchmark to correlate server work with process resources.'}</p>
        </div>

        <div className="controls" aria-label="Dashboard controls">
          <label className="select-field">
            <span>Run</span>
            <select value={selectedRunID} onChange={(event) => setSelectedRunID(event.target.value)}>
              {runs.map((run) => (
                <option key={run.id} value={run.id}>
                  {run.id}
                </option>
              ))}
            </select>
          </label>

          <label className="switch">
            <input type="checkbox" checked={showRuntimeEvents} onChange={(event) => setShowRuntimeEvents(event.target.checked)} />
            <span className="switch-track" aria-hidden="true"><span /></span>
            <span>Runtime events</span>
          </label>

          <label className="switch">
            <input type="checkbox" checked={showLatency} onChange={(event) => setShowLatency(event.target.checked)} />
            <span className="switch-track" aria-hidden="true"><span /></span>
            <span>Latency</span>
          </label>
        </div>
      </header>

      {error ? <ErrorBanner message={error} /> : null}

      <RunContext loaded={loaded} current={current} frame={frame} onFrameChange={handleFrameChange} />

      <section className="workspace" aria-label="Benchmark charts">
        <div className="chart-grid">
          {visibleMetricGroups.map((group) => (
            <MetricChart
              key={group.id}
              group={group}
              loaded={loaded}
              frame={frame}
              phases={loaded?.phases ?? []}
              showRuntimeEvents={showRuntimeEvents}
              runtimeMarkers={runtimeMarkers}
              onFrameChange={handleFrameChange}
            />
          ))}
        </div>
      </section>

      <EventPanel loaded={loaded} events={eventRows} />
    </main>
  );
}

function EmptyState() {
  return (
    <main className="shell empty-shell">
      <section className="empty-state">
        <Server size={28} />
        <h1>HTTP JSON Server Activity</h1>
        <p>Generate a run with <code>./scripts/run-local.sh</code>, then rebuild the web app to inspect the dataset.</p>
      </section>
    </main>
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

function RunContext({ loaded, current, frame, onFrameChange }) {
  const metadata = loaded?.metadata;
  const summary = loaded?.summary;
  const row = current?.row ?? {};
  const maxElapsed = loaded?.maxElapsed ?? 0;
  const progress = maxElapsed > 0 ? (frame / maxElapsed) * 100 : 0;

  return (
    <section className="run-context" aria-label="Run context">
      <div className="run-meta">
        <div>
          <span className="label">Server</span>
          <strong>{metadata ? `${metadata.server} · ${metadata.runtime ?? metadata.language ?? 'runtime'}` : '--'}</strong>
        </div>
        <div>
          <span className="label">Started</span>
          <strong>{metadata ? formatRunDate(metadata.started_at) : '--'}</strong>
        </div>
        <div>
          <span className="label">Connection Targets</span>
          <strong>{formatTargets(metadata?.connection_targets ?? summary?.connection_targets)}</strong>
        </div>
        <div>
          <span className="label">Target RPS</span>
          <strong>{metadata ? formatRate(metadata.target_requests_per_second) : '--'}</strong>
        </div>
        <div>
          <span className="label">Payload</span>
          <strong>{metadata ? `${formatNumber(metadata.payload_bytes)} B` : '--'}</strong>
        </div>
      </div>

      <div className="timeline-panel" aria-label="Timeline scrubber">
        <div className="panel-heading">
          <div>
            <span className="label">Timeline</span>
            <h2>{formatDuration(frame)} / {formatDuration(maxElapsed)}</h2>
          </div>
          <span className="phase-badge">{row.phase ?? 'idle'}{row.targetConnections ? ` · ${formatCompact(row.targetConnections)} conn` : ''}</span>
        </div>

        <div className="phase-track" aria-hidden="true">
          {(loaded?.phases ?? []).length === 0 ? <span className="phase-segment skeleton" /> : loaded.phases.map((phase) => {
            const left = maxElapsed > 0 ? (phase.start / maxElapsed) * 100 : 0;
            const width = maxElapsed > 0 ? Math.max(1.5, ((phase.end - phase.start) / maxElapsed) * 100) : 100;
            return (
              <span
                key={`${phase.name}-${phase.stageIndex}-${phase.start}`}
                className="phase-segment"
                style={{ left: `${left}%`, width: `${width}%`, backgroundColor: phaseColors[phase.name] ?? phaseColors.unknown }}
              />
            );
          })}
          <span className="playhead" style={{ left: `${progress}%` }} />
        </div>

        <input
          className="scrubber"
          type="range"
          min="0"
          max={maxElapsed}
          value={frame}
          step="1"
          onChange={(event) => onFrameChange(event.target.value)}
          aria-label="Timeline"
          disabled={!loaded}
        />
      </div>
    </section>
  );
}

function MetricChart({ group, loaded, frame, phases, showRuntimeEvents, runtimeMarkers, onFrameChange }) {
  const data = loaded?.timeline ?? [];
  const maxElapsed = loaded?.maxElapsed ?? 1;
  const [surfaceRef, surfaceSize] = useElementSize();
  const chartReady = surfaceSize.width > 0 && surfaceSize.height > 0;

  return (
    <article className={`chart-card chart-card-${group.id}`}>
      <div className="chart-header">
        <div>
          <h3>{group.title}</h3>
          <p>{group.description}</p>
        </div>
        <span><MousePointer2 size={14} /> {formatDuration(frame)}</span>
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
            syncId="server-benchmark"
            onClick={(event) => {
              if (event?.activeLabel != null) onFrameChange(event.activeLabel);
            }}
          >
            <CartesianGrid stroke="#e7ebf0" strokeDasharray="3 4" vertical={false} />
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
              minTickGap={28}
              tickFormatter={(value) => `${Math.round(value)}s`}
              stroke="#667085"
              fontSize={12}
            />
            <YAxis
              yAxisId="left"
              tickLine={false}
              axisLine={false}
              width={52}
              stroke="#667085"
              fontSize={12}
              tickFormatter={formatCompact}
            />
            {group.dualAxis ? (
              <YAxis
                yAxisId="right"
                orientation="right"
                tickLine={false}
                axisLine={false}
                width={46}
                stroke="#92400e"
                fontSize={12}
                tickFormatter={formatCompact}
              />
            ) : null}
            <Tooltip content={<ChartTooltip group={group} />} cursor={{ stroke: '#111827', strokeWidth: 1 }} />
            <Legend verticalAlign="top" height={30} iconType="circle" wrapperStyle={{ fontSize: 12, paddingBottom: 6 }} />
            {group.series.map((series) => (
              <Line
                key={series.key}
                yAxisId={series.axis === 'right' ? 'right' : 'left'}
                type="monotone"
                dataKey={series.key}
                name={series.label}
                stroke={series.color}
                strokeWidth={2.25}
                dot={false}
                connectNulls
                activeDot={{ r: 4, strokeWidth: 0 }}
                isAnimationActive={false}
              />
            ))}
            {showRuntimeEvents ? runtimeMarkers.map((event, index) => (
              <ReferenceLine
                key={`${group.id}-runtime-${event.second}-${index}`}
                x={event.second}
                yAxisId="left"
                stroke={event.kind === 'major' ? '#b42318' : '#475467'}
                strokeDasharray={event.kind === 'major' ? undefined : '3 3'}
                strokeOpacity={0.7}
                label={group.id === 'runtime' && event.kind === 'major' ? { value: 'GC', position: 'insideTop', fill: '#b42318', fontSize: 10 } : undefined}
              />
            )) : null}
            <ReferenceLine x={frame} yAxisId="left" stroke="#111827" strokeWidth={1.4} ifOverflow="extendDomain" />
          </LineChart>
        )}
      </div>
    </article>
  );
}

function EventPanel({ loaded, events }) {
  return (
    <section className="event-panel" aria-label="Recent errors and events">
      <div className="chart-header">
        <div>
          <h3>Errors And Diagnostics</h3>
          <p>Recent server-side events and loadgen-observed failures through the selected time.</p>
        </div>
      </div>

      {!loaded ? (
        <div className="event-empty">No data</div>
      ) : events.length === 0 ? (
        <div className="event-empty">No server or loadgen errors through this point.</div>
      ) : (
        <div className="event-table" role="table">
          <div className="event-row event-row-head" role="row">
            <span>Time</span>
            <span>Source</span>
            <span>Event</span>
            <span>Reason</span>
          </div>
          {events.map((event, index) => (
            <div className="event-row" role="row" key={`${event.source}-${event.timeline_seconds}-${index}`}>
              <span>{formatDuration(event.timeline_seconds)}</span>
              <span>{event.source}</span>
              <span>{event.event ?? 'event'}</span>
              <span>{event.reason ?? event.error ?? event.message ?? '--'}</span>
            </div>
          ))}
        </div>
      )}
    </section>
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
        <strong>{formatDuration(label)}</strong>
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

function subtitleFor(metadata) {
  return `${metadata.server} | ${formatTargets(metadata.connection_targets)} connections | ${formatNumber(metadata.payload_bytes)}B payload | ${formatRate(metadata.target_requests_per_second)}`;
}

function formatTargets(values) {
  if (!Array.isArray(values) || values.length === 0) return '--';
  return values.map((value) => formatCompact(value)).join(' → ');
}
