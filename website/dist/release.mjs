export function validateRelease(data, baseURL) {
  if (!data || data.released !== true || data.architecture !== 'arm64') return null;
  if (typeof data.version !== 'string' || !/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/.test(data.version)) return null;
  if (!['string', 'number'].includes(typeof data.build) || !/^[1-9]\d*$/.test(String(data.build))) return null;
  if (typeof data.minimumMacOS !== 'string' || !/^\d+\.\d+(?:\.\d+)?$/.test(data.minimumMacOS) || Number(data.minimumMacOS.split('.')[0]) < 26) return null;
  if (typeof data.sha256 !== 'string' || !/^[a-f0-9]{64}$/i.test(data.sha256)) return null;
  if (typeof data.downloadURL !== 'string' || !data.downloadURL || /[\s\\]/.test(data.downloadURL) || /^[#?]/.test(data.downloadURL) || data.downloadURL.startsWith('//')) return null;
  try {
    const url = new URL(data.downloadURL, baseURL);
    const absolute = /^[a-z][a-z\d+.-]*:/i.test(data.downloadURL);
    if ((absolute && url.protocol !== 'https:') || (!absolute && !['http:', 'https:'].includes(url.protocol)) || url.username || url.password) return null;
    return {
      released: true,
      version: data.version,
      build: String(data.build),
      downloadURL: url.href,
      sha256: data.sha256.toLowerCase(),
      minimumMacOS: data.minimumMacOS,
      architecture: data.architecture,
    };
  } catch {
    return null;
  }
}

export async function loadRelease(fetcher, baseURL) {
  try {
    const response = await fetcher(new URL('./releases/latest.json', baseURL).href, {
      cache: 'no-store',
      headers: { Accept: 'application/json' },
    });
    return response.ok ? validateRelease(await response.json(), baseURL) : null;
  } catch {
    return null;
  }
}
