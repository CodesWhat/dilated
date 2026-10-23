export const directions = {
  counter: { name: 'Counter pack', font: 'barlow' },
  night: { name: 'Night shift', font: 'fraunces' },
  field: { name: 'Field notes', font: 'instrument' },
};
export const fonts = ['barlow', 'fraunces', 'instrument'];

export function readPreferences(search, saved = {}) {
  const params = new URLSearchParams(search);
  const concept = Object.hasOwn(directions, params.get('concept')) ? params.get('concept') : 'counter';
  const requested = params.get('font') || saved[concept];
  return { concept, font: fonts.includes(requested) ? requested : directions[concept].font };
}

export function remainingTime(deadline, now) {
  const seconds = deadline === null ? 1800 : Math.max(0, Math.ceil((deadline - now) / 1000));
  return `${String(Math.floor(seconds / 60)).padStart(2, '0')}:${String(seconds % 60).padStart(2, '0')}`;
}
