const numberFormatter = new Intl.NumberFormat();
const compactFormatter = new Intl.NumberFormat(undefined, {
  notation: 'compact',
  maximumFractionDigits: 1,
});

export function formatNumber(value) {
  return numberFormatter.format(Math.round(Number(value) || 0));
}

export function formatCompact(value) {
  return compactFormatter.format(Number(value) || 0);
}

export function formatFixed(value, digits = 1) {
  return (Number(value) || 0).toFixed(digits);
}

export function formatPercent(value) {
  return `${formatFixed(value, 1)}%`;
}

export function formatMB(value) {
  return `${formatFixed(value, 1)} MB`;
}

export function formatRate(value) {
  return `${formatNumber(value)}/s`;
}

export function formatLatency(value) {
  return `${formatFixed(value, 2)} ms`;
}

export function formatDuration(seconds) {
  const total = Math.max(0, Math.round(Number(seconds) || 0));
  const minutes = Math.floor(total / 60);
  const remaining = total % 60;
  if (minutes === 0) return `${remaining}s`;
  return `${minutes}m ${remaining.toString().padStart(2, '0')}s`;
}

export function formatRunDate(value) {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return 'Unknown start';
  return new Intl.DateTimeFormat(undefined, {
    month: 'short',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  }).format(date);
}

export function formatSeriesValue(value, unit) {
  if (value == null) return '';
  switch (unit) {
    case '%':
      return formatPercent(value);
    case 'MB':
      return formatMB(value);
    case 'ms':
      return formatLatency(value);
    case '/s':
      return formatRate(value);
    default:
      return formatNumber(value);
  }
}
