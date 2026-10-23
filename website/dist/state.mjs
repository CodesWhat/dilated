export const directions = {
  'gas-station': { name: 'Gas Station', font: 'barlow' },
  night: { name: 'Night shift', font: 'fraunces' },
  field: { name: 'Field notes', font: 'instrument' },
};
export function readPreferences(search) {
  const params = new URLSearchParams(search);
  const concept = Object.hasOwn(directions, params.get('concept')) ? params.get('concept') : 'gas-station';
  return { concept, font: directions[concept].font };
}

export function remainingTime(deadline, now) {
  const seconds = deadline === null ? 1800 : Math.max(0, Math.ceil((deadline - now) / 1000));
  return `${String(Math.floor(seconds / 60)).padStart(2, '0')}:${String(seconds % 60).padStart(2, '0')}`;
}
