export function validateRelease(data, baseURL) {
  if (!data || data.released !== true || data.architecture !== 'arm64') return null;
  if (typeof data.version !== 'string' || !/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/.test(data.version)) return null;
  if (!['string', 'number'].includes(typeof data.build) || !/^[1-9]\d*$/.test(String(data.build))) return null;
  if (typeof data.minimumMacOS !== 'string' || !/^\d+\.\d+(?:\.\d+)?$/.test(data.minimumMacOS) || Number(data.minimumMacOS.split('.')[0]) < 26) return null;
  if (typeof data.sha256 !== 'string' || !/^[a-f0-9]{64}$/i.test(data.sha256)) return null;
  if (typeof data.downloadURL !== 'string' || !data.downloadURL || /[\s\\]/.test(data.downloadURL) || /^[#?]/.test(data.downloadURL) || data.downloadURL.startsWith('//')) return null;
  if (data.prerelease !== undefined && typeof data.prerelease !== 'boolean') return null;
  if (data.unverified !== undefined && (!Array.isArray(data.unverified) || data.unverified.some(name => typeof name !== 'string'))) return null;
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
      prerelease: data.prerelease === true,
      unverified: data.unverified ? [...data.unverified] : [],
    };
  } catch {
    return null;
  }
}

export function releaseCopy(release) {
  const beta = release.prerelease;
  return {
    label: beta ? 'Download beta for Mac' : 'Download for Mac',
    copy: beta
      ? `Dilated ${release.version} is a public beta for macOS ${release.minimumMacOS}+ on Apple Silicon. Free software from CodesWhat, under MIT.`
      : `Dilated ${release.version} is ready for macOS ${release.minimumMacOS}+ on Apple Silicon. Free software from CodesWhat, under MIT.`,
    summary: `${beta ? 'BETA ' : 'V'}${release.version} · MACOS ${release.minimumMacOS}+ · APPLE SILICON · MIT LICENSE`,
    caveat: release.unverified.length
      ? `Closed-lid mode is experimental in this beta. Not yet verified on hardware: ${release.unverified.join(', ')}.`
      : '',
  };
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
