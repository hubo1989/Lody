import { describe, expect, it } from 'vitest';
import {
  countBillableSessionTurns,
  evaluateBillingQuota,
  evaluateSessionCreateQuota,
  formatSessionQuotaRejection,
  FREE_SESSION_LIMIT_PER_WORKSPACE,
  FREE_SESSION_TURN_LIMIT,
  isBillingQuotaExempt,
} from '../src/billing';
import { shouldBypassSessionQuota } from '../src/session-orchestration';

/**
 * Fork compat layer: the stock quota assertions below are wrapped in
 * `describe.skipIf` so the same suite verifies both modes:
 *
 *   default (no env)            -> compat layer active, every quota admits
 *   LODY_QUOTA_LIMITS=billing   -> stock upstream gating behavior
 *
 * Upstream edits to these cases keep merging cleanly; only this wrapper
 * comment and the compat-only describe block are fork-local.
 */
const STOCK_QUOTAS = process.env.LODY_QUOTA_LIMITS === 'billing';

describe.skipIf(!STOCK_QUOTAS)('evaluateBillingQuota', () => {
  it('blocks known free plans at the limit', () => {
    expect(
      evaluateBillingQuota({
        effectivePlanTier: 'free',
        current: FREE_SESSION_TURN_LIMIT,
        limit: FREE_SESSION_TURN_LIMIT,
      })
    ).toEqual({
      allowed: false,
      reason: 'limit_reached',
      current: FREE_SESSION_TURN_LIMIT,
      limit: FREE_SESSION_TURN_LIMIT,
    });
  });

  it('fails open when entitlement is unavailable', () => {
    expect(
      evaluateBillingQuota({
        effectivePlanTier: undefined,
        current: FREE_SESSION_TURN_LIMIT,
        limit: FREE_SESSION_TURN_LIMIT,
      })
    ).toEqual({ allowed: true });
  });

  it('allows paid plans above the free limit', () => {
    expect(
      evaluateBillingQuota({
        effectivePlanTier: 'plus',
        current: FREE_SESSION_TURN_LIMIT + 1,
        limit: FREE_SESSION_TURN_LIMIT,
      })
    ).toEqual({ allowed: true });
  });

  it('blocks checkout-pending workspaces before evaluating the plan', () => {
    expect(
      evaluateBillingQuota({
        effectivePlanTier: undefined,
        checkoutPending: true,
        current: 0,
        limit: FREE_SESSION_TURN_LIMIT,
      })
    ).toEqual({
      allowed: false,
      reason: 'checkout_pending',
      current: 0,
      limit: FREE_SESSION_TURN_LIMIT,
    });
  });
});

describe.skipIf(STOCK_QUOTAS)('evaluateBillingQuota (compat layer)', () => {
  it('admits every tier regardless of the count', () => {
    expect(
      evaluateBillingQuota({
        effectivePlanTier: 'free',
        current: FREE_SESSION_TURN_LIMIT + 10,
        limit: FREE_SESSION_TURN_LIMIT,
      })
    ).toEqual({ allowed: true });
    expect(
      evaluateBillingQuota({
        effectivePlanTier: undefined,
        current: Number.MAX_SAFE_INTEGER,
        limit: FREE_SESSION_TURN_LIMIT,
      })
    ).toEqual({ allowed: true });
  });

  it('admits even with checkout pending', () => {
    expect(
      evaluateBillingQuota({
        effectivePlanTier: 'free',
        checkoutPending: true,
        current: 0,
        limit: FREE_SESSION_TURN_LIMIT,
      })
    ).toEqual({ allowed: true });
  });
});

describe('formatSessionQuotaRejection', () => {
  it('keeps create and turn quota copy centralized', () => {
    expect(
      formatSessionQuotaRejection('session_create', {
        allowed: false,
        reason: 'limit_reached',
        current: 200,
        limit: 200,
      })
    ).toBe('Free workspaces can create up to 200 sessions (currently 200).');
    expect(
      formatSessionQuotaRejection('session_turn', {
        allowed: false,
        reason: 'checkout_pending',
        current: 0,
        limit: 30,
      })
    ).toBe('Complete checkout before sending messages in this workspace.');
  });
});

describe('shouldBypassSessionQuota', () => {
  it('bypasses quotas only for durable batch commands', () => {
    expect(shouldBypassSessionQuota('session_create_many')).toBe(true);
    expect(shouldBypassSessionQuota('session_chat_many')).toBe(true);
    expect(shouldBypassSessionQuota('session_create')).toBe(false);
    expect(shouldBypassSessionQuota('session_chat')).toBe(false);
  });
});

describe.skipIf(!STOCK_QUOTAS)('evaluateSessionCreateQuota', () => {
  it('fails the count-based cap open while the session index has not hydrated', () => {
    expect(
      evaluateSessionCreateQuota({ effectivePlanTier: 'free', sessionCount: null })
    ).toEqual({ allowed: true });
  });

  it('still blocks a pending checkout without a count', () => {
    expect(
      evaluateSessionCreateQuota({
        effectivePlanTier: 'free',
        checkoutPending: true,
        sessionCount: null,
      })
    ).toEqual({
      allowed: false,
      reason: 'checkout_pending',
      current: 0,
      limit: FREE_SESSION_LIMIT_PER_WORKSPACE,
    });
  });

  it('blocks free workspaces at the session cap', () => {
    expect(
      evaluateSessionCreateQuota({
        effectivePlanTier: 'free',
        sessionCount: FREE_SESSION_LIMIT_PER_WORKSPACE,
      })
    ).toEqual({
      allowed: false,
      reason: 'limit_reached',
      current: FREE_SESSION_LIMIT_PER_WORKSPACE,
      limit: FREE_SESSION_LIMIT_PER_WORKSPACE,
    });
  });
});

describe.skipIf(STOCK_QUOTAS)('evaluateSessionCreateQuota (compat layer)', () => {
  it('admits regardless of hydration or count', () => {
    expect(
      evaluateSessionCreateQuota({ effectivePlanTier: 'free', sessionCount: null })
    ).toEqual({ allowed: true });
    expect(
      evaluateSessionCreateQuota({
        effectivePlanTier: 'free',
        sessionCount: FREE_SESSION_LIMIT_PER_WORKSPACE + 1,
      })
    ).toEqual({ allowed: true });
    expect(
      evaluateSessionCreateQuota({
        effectivePlanTier: 'free',
        checkoutPending: true,
        sessionCount: 0,
      })
    ).toEqual({ allowed: true });
  });
});

describe.skipIf(!STOCK_QUOTAS)('isBillingQuotaExempt', () => {
  it('exempts only paid workspaces with no pending checkout', () => {
    expect(isBillingQuotaExempt({ effectivePlanTier: 'plus' })).toBe(true);
    expect(isBillingQuotaExempt({ effectivePlanTier: 'plus', checkoutPending: true })).toBe(false);
    expect(isBillingQuotaExempt({ effectivePlanTier: 'free' })).toBe(false);
    // Unknown entitlement fails open, matching evaluateBillingQuota.
    expect(isBillingQuotaExempt({ effectivePlanTier: undefined })).toBe(true);
  });
});

describe.skipIf(STOCK_QUOTAS)('isBillingQuotaExempt (compat layer)', () => {
  it('exempts every workspace', () => {
    expect(isBillingQuotaExempt({ effectivePlanTier: 'free' })).toBe(true);
    expect(isBillingQuotaExempt({ effectivePlanTier: 'plus', checkoutPending: true })).toBe(true);
    expect(isBillingQuotaExempt({ effectivePlanTier: undefined })).toBe(true);
  });
});

describe.skipIf(!STOCK_QUOTAS)('free quota constants', () => {
  it('keeps the stock caps', () => {
    expect(FREE_SESSION_LIMIT_PER_WORKSPACE).toBe(200);
    expect(FREE_SESSION_TURN_LIMIT).toBe(30);
  });
});

describe.skipIf(STOCK_QUOTAS)('free quota constants (compat layer)', () => {
  it('raises the caps beyond practical counts', () => {
    expect(FREE_SESSION_LIMIT_PER_WORKSPACE).toBeGreaterThan(1_000_000);
    expect(FREE_SESSION_TURN_LIMIT).toBeGreaterThan(1_000_000);
  });
});

describe('countBillableSessionTurns', () => {
  it('counts user history entries and queued prompts', () => {
    expect(
      countBillableSessionTurns({
        history: [{ role: 'user' }, { role: 'assistant' }, { role: 'user' }],
        queue: [{ task: 'queued one' }, { task: 'queued two' }],
      })
    ).toBe(4);
  });
});
