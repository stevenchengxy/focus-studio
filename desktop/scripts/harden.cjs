'use strict';
const path = require('node:path');
module.exports = async function harden(context) {
  const {flipFuses, FuseVersion, FuseV1Options} = await import('@electron/fuses');
  const binary = path.join(context.appOutDir, context.electronPlatformName === 'win32'
    ? `${context.packager.appInfo.productFilename}.exe` : 'focus-studio-desktop');
  if (context.electronPlatformName === 'darwin') return; // The separate Swift macOS release is not packaged here.
  await flipFuses(binary, {
    version: FuseVersion.V1,
    [FuseV1Options.RunAsNode]: false,
    [FuseV1Options.EnableNodeOptionsEnvironmentVariable]: false,
    [FuseV1Options.EnableNodeCliInspectArguments]: false,
    [FuseV1Options.EnableCookieEncryption]: true,
    [FuseV1Options.OnlyLoadAppFromAsar]: true,
    [FuseV1Options.GrantFileProtocolExtraPrivileges]: false,
    ...(context.electronPlatformName === 'win32' ? {[FuseV1Options.EnableEmbeddedAsarIntegrityValidation]: true} : {})
  });
};
