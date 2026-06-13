import { useEffect, useMemo, useRef, useState } from 'react';
import {
  Activity,
  AlertTriangle,
  BarChart3,
  Cable,
  CheckCircle2,
  Clock3,
  Cpu,
  Gauge,
  HardDrive,
  MessageSquareText,
  MousePointer2,
  Server,
  Sparkles,
  Zap,
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
  countGCEvents,
  fetchRuns,
  loadRun,
  metricGroups,
  nearestSample,
  phaseColors,
  significantGCEvents,
} from './data.js';
import {
  formatCompact,
  formatDuration,
  formatFixed,
  formatLatency,
  formatMB,
  formatNumber,
  formatPercent,
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
  const [showGC, setShowGC] = useState(true);
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
    const loadgen = nearestSample(loaded.loadgenMetrics, frame);
    const server = nearestSample(loaded.serverMetrics, frame);
    const runtime = nearestSample(loaded.runtimeMetrics, frame);

    return {
      row,
      loadgen,
      server,
      runtime,
      gcEvents: countGCEvents(loaded.runtimeEvents, frame),
    };
  }, [frame, loaded]);

  const gcMarkers = useMemo(() => (loaded ? significantGCEvents(loaded.runtimeEvents) : []), [loaded]);
  const selectedRun = runs.find((run) => run.id === selectedRunID);

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
          <div className="eyebrow"><BarChart3 size={16} /> Benchmark Replay</div>
          <h1>HTTP JSON Benchmark Replay</h1>
          <p>{loaded ? subtitleFor(loaded.metadata) : 'Load a run to inspect benchmark behavior over time.'}</p>
        </div>

        <div className="controls" aria-label="Replay controls">
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
            <input type="checkbox" checked={showGC} onChange={(event) => setShowGC(event.target.checked)} />
            <span className="switch-track" aria-hidden="true"><span /></span>
            <span>GC markers</span>
          </label>
        </div>
      </header>

      {error ? <ErrorBanner message={error} /> : null}

      <section className="summary-grid" aria-label="Run summary">
        <HeroPanel loaded={loaded} selectedRun={selectedRun} loading={loading} />
        <TimelinePanel loaded={loaded} current={current} frame={frame} onFrameChange={handleFrameChange} />
      </section>

      <MetricStrip loaded={loaded} current={current} showGC={showGC} />

      <section className="workspace" aria-label="Benchmark charts">
        <div className="chart-grid">
          {metricGroups.map((group) => (
            <MetricChart
              key={group.id}
              group={group}
              loaded={loaded}
              frame={frame}
              phases={loaded?.phases ?? []}
              showGC={showGC}
              gcMarkers={gcMarkers}
              onFrameChange={handleFrameChange}
            />
          ))}
        </div>
      </section>
    </main>
  );
}

function EmptyState() {
  return (
    <main className="shell empty-shell">
      <section className="empty-state">
        <Sparkles size={28} />
        <h1>HTTP JSON Benchmark Replay</h1>
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

function HeroPanel({ loaded, selectedRun, loading }) {
  const metadata = loaded?.metadata ?? selectedRun?.metadata;
  const summary = loaded?.summary;
  const status = loaded ? 'Loaded' : loading ? 'Loading' : 'Ready';
  const totalResponses = summary ? summary.total_received : targetRate(metadata);

  return (
    <section className="hero-panel" aria-label="Selected run details">
      <div className="hero-topline">
        <span className="status-pill"><CheckCircle2 size={15} /> {status}</span>
        <span>{metadata ? formatRunDate(metadata.started_at) : 'No run selected'}</span>
      </div>

      <div>
        <h2>{metadata?.server ?? 'Benchmark run'}</h2>
        <p>{metadata?.url ?? 'Waiting for run metadata.'}</p>
      </div>

      <dl className="hero-facts">
        <Fact icon={Cable} label="Connections" value={metadata ? formatNumber(metadata.connections) : '--'} />
        <Fact icon={MessageSquareText} label="Target rate" value={metadata ? formatRate(targetRate(metadata)) : '--'} />
        <Fact icon={HardDrive} label="Payload" value={metadata ? `${formatNumber(metadata.payload_bytes)} B` : '--'} />
        <Fact icon={Zap} label="Responses" value={totalResponses != null ? formatNumber(totalResponses) : '--'} />
      </dl>
    </section>
  );
}

function Fact({ icon: Icon, label, value }) {
  return (
    <div className="fact">
      <Icon size={17} />
      <dt>{label}</dt>
      <dd>{value}</dd>
    </div>
  );
}

function TimelinePanel({ loaded, current, frame, onFrameChange }) {
  const phases = loaded?.phases ?? [];
  const maxElapsed = loaded?.maxElapsed ?? 0;
  const progress = maxElapsed > 0 ? (frame / maxElapsed) * 100 : 0;

  return (
    <section className="timeline-panel" aria-label="Timeline scrubber">
      <div className="panel-heading">
        <div>
          <span className="label">Timeline</span>
          <h2>{formatDuration(frame)} / {formatDuration(maxElapsed)}</h2>
        </div>
        <span className="phase-badge">{current?.row?.phase ?? 'idle'}</span>
      </div>

      <div className="phase-track" aria-hidden="true">
        {phases.length === 0 ? <span className="phase-segment skeleton" /> : phases.map((phase) => {
          const left = maxElapsed > 0 ? (phase.start / maxElapsed) * 100 : 0;
          const width = maxElapsed > 0 ? Math.max(1.5, ((phase.end - phase.start) / maxElapsed) * 100) : 100;
          return (
            <span
              key={`${phase.name}-${phase.start}`}
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

      <div className="phase-legend">
        {phases.map((phase) => (
          <span key={`${phase.name}-legend-${phase.start}`}>
            <i style={{ backgroundColor: phaseColors[phase.name] ?? phaseColors.unknown }} />
            {phase.name}
          </span>
        ))}
      </div>
    </section>
  );
}

function MetricStrip({ loaded, current, showGC }) {
  const loadgen = current?.loadgen ?? {};
  const server = current?.server ?? {};
  const runtime = current?.runtime ?? {};
  const summary = loaded?.summary ?? {};
  const cards = [
    { icon: Cable, label: 'Connections', value: formatNumber(loadgen.active_connections), detail: `Peak ${formatNumber(summary.peak_active_connections ?? loadgen.active_connections)}` },
    { icon: Cpu, label: 'CPU', value: formatPercent(server.cpu_percent), detail: 'Server process' },
    { icon: HardDrive, label: 'RSS', value: formatMB(server.rss_mb), detail: 'Resident memory' },
    { icon: MessageSquareText, label: 'Responses', value: formatRate(loadgen.received_per_second), detail: `Requests ${formatRate(loadgen.sent_per_second)}` },
    { icon: Gauge, label: 'p99 latency', value: formatLatency(loadgen.p99_latency_ms), detail: `Max ${formatLatency(loadgen.max_latency_ms)}` },
    { icon: AlertTriangle, label: 'Errors', value: formatRate(loadgen.errors_per_second), detail: `${formatNumber(summary.total_errors ?? 0)} total` },
    { icon: Activity, label: 'Heap used', value: formatMB(runtime.heap_used_mb), detail: 'Runtime memory' },
    { icon: Clock3, label: 'GC events', value: showGC ? formatNumber(current?.gcEvents ?? 0) : 'Hidden', detail: 'Through playhead' },
  ];

  return (
    <section className="metric-strip" aria-label="Current metrics">
      {cards.map((card) => (
        <article key={card.label} className="metric-card">
          <div className="metric-icon"><card.icon size={18} /></div>
          <div>
            <span>{card.label}</span>
            <strong>{loaded ? card.value : '--'}</strong>
            <small>{loaded ? card.detail : 'Awaiting data'}</small>
          </div>
        </article>
      ))}
    </section>
  );
}

function MetricChart({ group, loaded, frame, phases, showGC, gcMarkers, onFrameChange }) {
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
            syncId="bench-replay"
            onClick={(event) => {
              if (event?.activeLabel != null) onFrameChange(event.activeLabel);
            }}
          >
            <CartesianGrid stroke="#e7ebf0" strokeDasharray="3 4" vertical={false} />
            {phases.map((phase) => (
              <ReferenceArea
                key={`${group.id}-${phase.name}-${phase.start}`}
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
              width={48}
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
                width={42}
                stroke="#92400e"
                fontSize={12}
                tickFormatter={(value) => `${formatFixed(value, 0)}%`}
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
                activeDot={{ r: 4, strokeWidth: 0 }}
                isAnimationActive={false}
              />
            ))}
            {showGC ? gcMarkers.map((event, index) => (
              <ReferenceLine
                key={`${group.id}-gc-${event.second}-${index}`}
                x={event.second}
                yAxisId="left"
                stroke={event.kind === 'major' ? '#b42318' : '#475467'}
                strokeDasharray={event.kind === 'major' ? undefined : '3 3'}
                strokeOpacity={0.7}
                label={group.id === 'latency' && event.kind === 'major' ? { value: 'GC', position: 'insideTop', fill: '#b42318', fontSize: 10 } : undefined}
              />
            )) : null}
            <ReferenceLine x={frame} yAxisId="left" stroke="#111827" strokeWidth={1.4} ifOverflow="extendDomain" />
          </LineChart>
        )}
      </div>
    </article>
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
  return `${metadata.server} | ${formatNumber(metadata.connections)} connections | ${formatNumber(metadata.payload_bytes)}B payload | ${formatRate(targetRate(metadata))}`;
}

function targetRate(metadata) {
  return metadata?.target_requests_per_second ?? metadata?.target_messages_per_second ?? 0;
}
