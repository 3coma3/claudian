const mockGetHostnameKey = jest.fn(() => 'device:current');

import { getClaudeProviderSettings, updateClaudeProviderSettings } from '@/providers/claude/settings';

jest.mock('@/core/device/InstallationKey', () => ({
  ...jest.requireActual('@/core/device/InstallationKey'),
  getInstallationKey: () => mockGetHostnameKey(),
}));

describe('Claude settings normalization', () => {
  it.each(['Default', 'Concise'] as const)('persists the %s response style while preserving other settings', (responseStyle) => {
    const settings = { providerConfigs: { claude: { customModels: 'custom' } } };
    updateClaudeProviderSettings(settings, { responseStyle });
    expect(getClaudeProviderSettings(settings)).toMatchObject({ responseStyle });
    expect(settings.providerConfigs.claude.customModels).toBe('custom');
  });

  it.each([undefined, null, '', 'invalid', 42, {}, []])('normalizes invalid response style %p to Default', (responseStyle) => {
    expect(getClaudeProviderSettings({ providerConfigs: { claude: { responseStyle } } }))
      .toMatchObject({ responseStyle: 'Default' });
  });

  it('normalizes mixed CLI maps without interpreting host-shaped keys', () => {
    expect(getClaudeProviderSettings({
      providerConfigs: {
        claude: {
          cliPathsByHost: {
            ' legacy-host ': ' /legacy/claude ',
            invalid: 42,
            empty: '',
          },
        },
      },
    }).cliPathsByHost).toEqual({
      'legacy-host': '/legacy/claude',
    });
  });

  it('rejects arrays as CLI maps', () => {
    expect(getClaudeProviderSettings({
      providerConfigs: { claude: { cliPathsByHost: ['/array/claude'] } },
    }).cliPathsByHost).toEqual({});
  });

  it('saves always-allow rules to project settings unless local settings are chosen', () => {
    expect(getClaudeProviderSettings({}).permissionDestination).toBe('projectSettings');
    expect(getClaudeProviderSettings({
      providerConfigs: { claude: { permissionDestination: 'localSettings' } },
    }).permissionDestination).toBe('localSettings');
    expect(getClaudeProviderSettings({
      providerConfigs: { claude: { permissionDestination: 'userSettings' } },
    }).permissionDestination).toBe('projectSettings');
  });

  it('ignores an unsupported always-allow destination update', () => {
    const settings: Record<string, unknown> = {
      providerConfigs: { claude: { permissionDestination: 'localSettings' } },
    };
    expect(updateClaudeProviderSettings(settings, {
      permissionDestination: 'session' as never,
    }).permissionDestination).toBe('localSettings');
  });
});
