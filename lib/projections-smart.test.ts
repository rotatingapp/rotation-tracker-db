import { describe, it, expect } from 'vitest';
import { generateProjections } from './projections.js';
import {
	expandImportantDates,
	generateSmartProjections,
	scoreImportantDates,
	type ImportantDate,
	type SmartContext,
	type SmartProjectionConfig,
} from './projections-smart.js';

// ---------------------------------------------------------------------------
// Fixture helpers
// ---------------------------------------------------------------------------

function idate(
	date: string,
	priority = 3,
	label = 'date',
	recur_yearly = false
): ImportantDate {
	return { date, label, priority, recur_yearly };
}

// ---------------------------------------------------------------------------
// expandImportantDates — edge case 9 (past dates, recurrence)
// ---------------------------------------------------------------------------

describe('expandImportantDates', () => {
	it('drops past important dates, keeps today and future (edge case 9)', () => {
		const out = expandImportantDates(
			[idate('2026-03-01'), idate('2026-06-11'), idate('2026-07-01')],
			'2026-01-01',
			'2026-12-31',
			'2026-06-11'
		);
		expect(out.map((d) => d.date)).toEqual(['2026-06-11', '2026-07-01']);
	});

	it('expands recur_yearly anchors to every occurrence inside the window', () => {
		const out = expandImportantDates(
			[idate('2020-03-15', 5, 'Anniversary', true)],
			'2026-01-01',
			'2027-12-31',
			'2026-01-01'
		);
		expect(out.map((d) => d.date)).toEqual(['2026-03-15', '2027-03-15']);
		expect(out.every((d) => d.label === 'Anniversary' && d.priority === 5)).toBe(true);
	});

	it('recurrence occurrences before today are dropped too', () => {
		const out = expandImportantDates(
			[idate('2020-03-15', 5, 'Anniversary', true)],
			'2026-01-01',
			'2027-12-31',
			'2026-06-11'
		);
		expect(out.map((d) => d.date)).toEqual(['2027-03-15']);
	});

	it('maps Feb-29 anchors to Feb-28 in non-leap years', () => {
		const out = expandImportantDates(
			[idate('2024-02-29', 4, 'Leap birthday', true)],
			'2026-01-01',
			'2026-12-31',
			'2026-01-01'
		);
		expect(out.map((d) => d.date)).toEqual(['2026-02-28']);
	});

	it('drops non-recurring dates outside the window', () => {
		const out = expandImportantDates(
			[idate('2028-01-01')],
			'2026-01-01',
			'2027-12-31',
			'2026-01-01'
		);
		expect(out).toEqual([]);
	});

	it('returns deterministic order: date asc, then priority desc, then label asc', () => {
		const out = expandImportantDates(
			[idate('2026-08-01', 2, 'b'), idate('2026-08-01', 5, 'a'), idate('2026-07-01', 1, 'c')],
			'2026-01-01',
			'2026-12-31',
			'2026-01-01'
		);
		expect(out.map((d) => `${d.date}/${d.priority}/${d.label}`)).toEqual([
			'2026-07-01/1/c',
			'2026-08-01/5/a',
			'2026-08-01/2/b',
		]);
	});
});

// ---------------------------------------------------------------------------
// scoreImportantDates — objective function (06-PROJ-SPEC §3)
// ---------------------------------------------------------------------------

describe('scoreImportantDates', () => {
	const rotations = [
		{ start_date: '2026-01-01', end_date: '2026-01-28', rotation_type: 'onboard' as const },
		{ start_date: '2026-01-29', end_date: '2026-02-25', rotation_type: 'off' as const },
	];

	it('scores priority × 10 for dates inside an off period; onboard and uncovered score 0', () => {
		const out = scoreImportantDates(rotations, [
			idate('2026-02-10', 2), // off → satisfied
			idate('2026-01-15', 5), // onboard → not
			idate('2026-03-01', 3), // outside coverage → not
		]);
		expect(out).toEqual({ satisfied: 1, total: 3, score: 20 });
	});

	it('off-period boundaries are inclusive on both ends', () => {
		const out = scoreImportantDates(rotations, [
			idate('2026-01-29', 1),
			idate('2026-02-25', 1),
		]);
		expect(out).toEqual({ satisfied: 2, total: 2, score: 20 });
	});
});

// ---------------------------------------------------------------------------
// generateSmartProjections — boundary optimisation
// ---------------------------------------------------------------------------

// Canonical 28/28 fixture starting onboard 2026-01-01, 3 cycles:
//   P0 on  Jan 1–28 · P1 off Jan 29–Feb 25 · P2 on Feb 26–Mar 25
//   P3 off Mar 26–Apr 22 · P4 on Apr 23–May 20 · P5 off May 21–Jun 17
function baseConfig(overrides: Partial<SmartProjectionConfig> = {}): SmartProjectionConfig {
	return {
		userId: 'user-1',
		crewMember: 'crew_a',
		startDate: '2026-01-01',
		startState: 'onboard',
		daysOn: 28,
		daysOff: 28,
		cycles: 3,
		...overrides,
	};
}

function emptyContext(overrides: Partial<SmartContext> = {}): SmartContext {
	return {
		lockedRotations: [],
		partnerOnboard: [],
		importantDates: [],
		blackouts: [],
		...overrides,
	};
}

describe('generateSmartProjections — baseline (no context)', () => {
	it('reduces to the linear projection when nothing constrains it', () => {
		const result = generateSmartProjections(baseConfig(), emptyContext());
		const linear = generateProjections({
			userId: 'user-1',
			startDate: '2026-01-01',
			startState: 'onboard',
			daysOn: 28,
			daysOff: 28,
			cycles: 3,
			crewMember: 'crew_a',
		});
		expect(result.rotations).toEqual(linear);
		expect(result.decisions.every((d) => d.reason === 'nominal' && d.shiftDays === 0)).toBe(true);
		expect(result.score).toEqual({
			importantDatesSatisfied: 0,
			importantDatesTotal: 0,
			importantDateScore: 0,
			driftPenalty: 0,
			total: 0,
		});
		expect(result.unresolved).toEqual([]);
	});

	it('returns an empty plan for zero cycles', () => {
		const result = generateSmartProjections(baseConfig({ cycles: 0 }), emptyContext());
		expect(result.rotations).toEqual([]);
		expect(result.decisions).toEqual([]);
	});
});

describe('generateSmartProjections — important dates', () => {
	it('shifts a boundary to put a high-priority date off (minimal shift wins)', () => {
		// 2026-03-23 is onboard (P2) under the linear plan; off-start boundary 3
		// (nominal Mar 26) shifting −3 → Mar 23 makes it the first off day.
		const result = generateSmartProjections(
			baseConfig(),
			emptyContext({ importantDates: [idate('2026-03-23', 5, 'Anniversary')] })
		);

		const d3 = result.decisions.find((d) => d.periodIndex === 3)!;
		expect(d3.chosenDate).toBe('2026-03-23');
		expect(d3.shiftDays).toBe(-3);
		expect(d3.reason).toBe('important-date');

		// Emitted periods reflect the shift
		expect(result.rotations[2]).toMatchObject({
			rotation_type: 'onboard',
			start_date: '2026-02-26',
			end_date: '2026-03-22',
		});
		expect(result.rotations[3]).toMatchObject({
			rotation_type: 'off',
			start_date: '2026-03-23',
			end_date: '2026-04-22',
		});

		expect(result.score).toEqual({
			importantDatesSatisfied: 1,
			importantDatesTotal: 1,
			importantDateScore: 50,
			driftPenalty: 3,
			total: 47,
		});
		expect(result.unresolved).toEqual([]);
	});

	it('does not propagate a shift to later boundaries (no compounding drift — edge case 6)', () => {
		const result = generateSmartProjections(
			baseConfig(),
			emptyContext({ importantDates: [idate('2026-03-23', 5, 'Anniversary')] })
		);
		const d4 = result.decisions.find((d) => d.periodIndex === 4)!;
		const d5 = result.decisions.find((d) => d.periodIndex === 5)!;
		// Later boundaries stay anchored to the nominal grid, not the shifted neighbour
		expect(d4.chosenDate).toBe('2026-04-23');
		expect(d4.shiftDays).toBe(0);
		expect(d5.chosenDate).toBe('2026-05-21');
		expect(d5.shiftDays).toBe(0);
	});

	it('defaults flexDays to 7: a −7 shift is reachable, −8 is not (edge case 5)', () => {
		// Boundary 3 (nominal Mar 26): 2026-03-19 needs −7 (just inside default
		// flex), 2026-03-18 would need −8 (just outside).
		const reachable = generateSmartProjections(
			baseConfig(),
			emptyContext({ importantDates: [idate('2026-03-19', 5, 'Edge')] })
		);
		expect(reachable.decisions.find((d) => d.periodIndex === 3)!.shiftDays).toBe(-7);
		expect(reachable.score.importantDatesSatisfied).toBe(1);

		const unreachable = generateSmartProjections(
			baseConfig(),
			emptyContext({ importantDates: [idate('2026-03-18', 5, 'Edge')] })
		);
		expect(unreachable.decisions.every((d) => d.shiftDays === 0)).toBe(true);
		expect(unreachable.unresolved).toEqual([
			{ date: '2026-03-18', label: 'Edge', priority: 5, reason: 'out-of-flex' },
		]);
	});

	it('never shifts for an already-satisfied date', () => {
		// 2026-02-10 is off (P1) under the linear plan already
		const result = generateSmartProjections(
			baseConfig(),
			emptyContext({ importantDates: [idate('2026-02-10', 5, 'Birthday')] })
		);
		expect(result.decisions.every((d) => d.shiftDays === 0)).toBe(true);
		expect(result.score.importantDateScore).toBe(50);
		expect(result.score.driftPenalty).toBe(0);
	});
});

describe('generateSmartProjections — blackouts (edge case 3)', () => {
	it('moves a boundary out of a blackout window', () => {
		// Blackout covers nominal boundary 3 (Mar 26); nearest valid day is Mar 23 (−3)
		const result = generateSmartProjections(
			baseConfig(),
			emptyContext({
				blackouts: [{ start_date: '2026-03-24', end_date: '2026-03-28', title: 'Drydock' }],
			})
		);
		const d3 = result.decisions.find((d) => d.periodIndex === 3)!;
		expect(d3.chosenDate).toBe('2026-03-23');
		expect(d3.shiftDays).toBe(-3);
		expect(d3.reason).toBe('blackout');
	});

	it('keeps the nominal boundary and reports detail when the blackout swallows the flex window', () => {
		// Mar 19 – Apr 2 covers Mar 26 ± 7 entirely
		const result = generateSmartProjections(
			baseConfig(),
			emptyContext({
				blackouts: [{ start_date: '2026-03-19', end_date: '2026-04-02', title: 'Owner trip' }],
			})
		);
		const d3 = result.decisions.find((d) => d.periodIndex === 3)!;
		expect(d3.chosenDate).toBe('2026-03-26');
		expect(d3.shiftDays).toBe(0);
		expect(d3.reason).toBe('nominal');
		expect(d3.detail).toBeTruthy();
	});

	it('normalises null end_date to a single-day blackout', () => {
		const result = generateSmartProjections(
			baseConfig(),
			emptyContext({
				blackouts: [{ start_date: '2026-03-26', end_date: null, title: 'Crew change frozen' }],
			})
		);
		const d3 = result.decisions.find((d) => d.periodIndex === 3)!;
		// Nominal day itself blocked; ±1 valid; candidate order prefers −1
		expect(d3.chosenDate).toBe('2026-03-25');
		expect(d3.shiftDays).toBe(-1);
	});
});

describe('generateSmartProjections — statutory rest / max onboard (edge case 2)', () => {
	it('maxOnboardDays caps how far an off-start boundary may be pushed', () => {
		// Blackout Mar 19–27 leaves only positive candidates for boundary 3;
		// +2 (Mar 28) stretches onboard P2 to 30 days.
		const blackouts = [{ start_date: '2026-03-19', end_date: '2026-03-27' }];

		const allowed = generateSmartProjections(
			baseConfig({ maxOnboardDays: 30 }),
			emptyContext({ blackouts })
		);
		const d3a = allowed.decisions.find((d) => d.periodIndex === 3)!;
		expect(d3a.chosenDate).toBe('2026-03-28');
		expect(d3a.shiftDays).toBe(2);

		const capped = generateSmartProjections(
			baseConfig({ maxOnboardDays: 29 }),
			emptyContext({ blackouts })
		);
		const d3b = capped.decisions.find((d) => d.periodIndex === 3)!;
		// 30-day onboard now violates the cap — no valid candidate remains
		expect(d3b.chosenDate).toBe('2026-03-26');
		expect(d3b.shiftDays).toBe(0);
		expect(d3b.detail).toBeTruthy();
	});

	it('minOffDays rejects candidates that would compress an off period', () => {
		// Blackout 1 forces boundary 3 (off start) to +7 → Apr 2.
		// Blackout 2 covers boundary 4's nominal region; the only escape is
		// negative shifts (Apr 16–19), which compress the off period to 14–17 days.
		const blackouts = [
			{ start_date: '2026-03-19', end_date: '2026-04-01' },
			{ start_date: '2026-04-20', end_date: '2026-04-30' },
		];

		const strict = generateSmartProjections(
			baseConfig({ minOffDays: 21 }),
			emptyContext({ blackouts })
		);
		const d4s = strict.decisions.find((d) => d.periodIndex === 4)!;
		// All escapes rejected by minOffDays → boundary stays nominal
		expect(d4s.chosenDate).toBe('2026-04-23');
		expect(d4s.shiftDays).toBe(0);

		const relaxed = generateSmartProjections(
			baseConfig({ minOffDays: 7 }),
			emptyContext({ blackouts })
		);
		const d4r = relaxed.decisions.find((d) => d.periodIndex === 4)!;
		// With the default-strength rest rule the −4 escape (Apr 19) is legal
		expect(d4r.chosenDate).toBe('2026-04-19');
		expect(d4r.shiftDays).toBe(-4);
	});
});

describe('generateSmartProjections — locked rotations (edge case 8)', () => {
	it('moves a boundary off a locked window', () => {
		const result = generateSmartProjections(
			baseConfig(),
			emptyContext({
				lockedRotations: [{ start_date: '2026-03-25', end_date: '2026-03-27' }],
			})
		);
		const d3 = result.decisions.find((d) => d.periodIndex === 3)!;
		expect(d3.chosenDate).toBe('2026-03-24');
		expect(d3.shiftDays).toBe(-2);
		expect(d3.reason).toBe('locked');
	});

	it('respects locked windows when projecting from a mid-year start', () => {
		// Reproject-forward flow (edge case 8): startDate = July 1, locked
		// rotation Jul 26 – Aug 2 sits over nominal boundary 1 (Jul 29).
		const result = generateSmartProjections(
			baseConfig({ startDate: '2026-07-01', cycles: 2 }),
			emptyContext({
				lockedRotations: [{ start_date: '2026-07-26', end_date: '2026-08-02' }],
			})
		);
		const d1 = result.decisions.find((d) => d.periodIndex === 1)!;
		expect(d1.chosenDate).toBe('2026-07-25');
		expect(d1.shiftDays).toBe(-4);
		expect(d1.reason).toBe('locked');
		expect(result.rotations[0]).toMatchObject({
			rotation_type: 'onboard',
			start_date: '2026-07-01',
			end_date: '2026-07-24',
		});
	});
});

describe('generateSmartProjections — partner conflicts (P-05, edge cases 1 & 10)', () => {
	// Partner is onboard Feb 20 – Mar 30: every candidate position of onboard
	// period P2 (nominal Feb 26 – Mar 25) overlaps — the period cannot commit.
	const partnerOnboard = [{ start_date: '2026-02-20', end_date: '2026-03-30' }];

	it('drops onboard periods overlapping partner onboard (P-05)', () => {
		const result = generateSmartProjections(baseConfig(), emptyContext({ partnerOnboard }));

		// 6 periods minus the dropped onboard P2
		expect(result.rotations).toHaveLength(5);
		expect(
			result.rotations.some(
				(r) => r.rotation_type === 'onboard' && r.start_date === '2026-02-26'
			)
		).toBe(false);
		// Neighbouring off periods are intact
		expect(result.rotations[1]).toMatchObject({
			rotation_type: 'off',
			start_date: '2026-01-29',
			end_date: '2026-02-25',
		});
		expect(result.rotations[2]).toMatchObject({
			rotation_type: 'off',
			start_date: '2026-03-26',
			end_date: '2026-04-22',
		});
	});

	it('reports partner-conflict when partner onboard blocks the only satisfying shift (edge case 10)', () => {
		const result = generateSmartProjections(
			baseConfig(),
			emptyContext({
				partnerOnboard,
				importantDates: [idate('2026-03-01', 4, 'School play')],
			})
		);
		expect(result.unresolved).toEqual([
			{ date: '2026-03-01', label: 'School play', priority: 4, reason: 'partner-conflict' },
		]);
	});
});

describe('generateSmartProjections — unresolved classification', () => {
	it('reports out-of-flex when no shift can reach the date', () => {
		// Blackout swallows boundary 3's whole flex window; 2026-03-20 needs
		// the off-start ≤ Mar 20, every such candidate is inside the blackout.
		const result = generateSmartProjections(
			baseConfig(),
			emptyContext({
				blackouts: [{ start_date: '2026-03-19', end_date: '2026-04-02', title: 'Owner trip' }],
				importantDates: [idate('2026-03-20', 3, 'Graduation')],
			})
		);
		expect(result.unresolved).toEqual([
			{ date: '2026-03-20', label: 'Graduation', priority: 3, reason: 'out-of-flex' },
		]);
	});

	it('satisfies multiple dates at one boundary when flex allows (edge case 4)', () => {
		// Satisfaction sets at a single boundary are monotone-nested, so the
		// score-max candidate satisfies both dates: +7 puts Feb 27 (P5) AND
		// Mar 4 (P2) off. A third date needing +8 is out of flex.
		const result = generateSmartProjections(
			baseConfig(),
			emptyContext({
				importantDates: [
					idate('2026-02-27', 5, 'Anniversary'),
					idate('2026-03-04', 2, 'Recital'),
					idate('2026-03-05', 1, 'Errand'),
				],
			})
		);
		const d2 = result.decisions.find((d) => d.periodIndex === 2)!;
		expect(d2.shiftDays).toBe(7);
		expect(d2.reason).toBe('important-date');
		expect(result.score.importantDatesSatisfied).toBe(2);
		expect(result.score.importantDateScore).toBe(70);
		expect(result.unresolved).toEqual([
			{ date: '2026-03-05', label: 'Errand', priority: 1, reason: 'out-of-flex' },
		]);
	});
});

describe('generateSmartProjections — smart beats linear (success criterion 5)', () => {
	// Year-plan seed: 7 cycles of 28/28 from 2026-01-01 (onboard first),
	// 7 important dates, one blackout over a boundary, partner onboard
	// overlapping one whole onboard period.
	const seedConfig = baseConfig({ cycles: 7 });
	const seedContext = emptyContext({
		importantDates: [
			idate('2026-03-23', 5, 'A-anniversary'),   // onboard in linear plan
			idate('2026-06-20', 4, 'B-graduation'),    // onboard in linear plan
			idate('2026-09-08', 3, 'C-birthday'),      // onboard in linear plan
			idate('2026-12-25', 5, 'D-christmas'),     // onboard in linear plan
			idate('2026-02-10', 2, 'E-checkup'),       // off in linear plan too
			idate('2026-07-30', 1, 'F-festival'),      // off in linear plan too
			idate('2026-10-10', 4, 'G-blocked'),       // inside partner-conflicted period
		],
		blackouts: [{ start_date: '2026-08-10', end_date: '2026-08-16', title: 'Drydock' }],
		partnerOnboard: [{ start_date: '2026-10-01', end_date: '2026-10-20' }],
	});

	it('scores measurably better than the linear projector on the same inputs', () => {
		const smart = generateSmartProjections(seedConfig, seedContext);
		const linear = generateProjections({
			userId: 'user-1',
			startDate: '2026-01-01',
			startState: 'onboard',
			daysOn: 28,
			daysOff: 28,
			cycles: 7,
			crewMember: 'crew_a',
		});
		const expanded = expandImportantDates(
			seedContext.importantDates,
			'2026-01-01',
			'2027-02-28',
			'2026-01-01'
		);
		const linearScore = scoreImportantDates(linear, expanded);

		expect(linearScore.score).toBe(30); // only E + F are off by luck
		expect(smart.score).toEqual({
			importantDatesSatisfied: 6,
			importantDatesTotal: 7,
			importantDateScore: 200,
			driftPenalty: 18,
			total: 182,
		});
		expect(smart.score.importantDateScore).toBeGreaterThan(linearScore.score);
		expect(smart.score.total).toBeGreaterThan(linearScore.score);
	});

	it('satisfies every hard constraint in the seed plan', () => {
		const smart = generateSmartProjections(seedConfig, seedContext);

		for (const r of smart.rotations) {
			const days =
				(Date.parse(r.end_date) - Date.parse(r.start_date)) / 86_400_000 + 1;
			if (r.rotation_type === 'off') expect(days).toBeGreaterThanOrEqual(7);
			if (r.rotation_type === 'onboard') {
				expect(days).toBeLessThanOrEqual(35);
				// P-05: no emitted onboard overlaps partner onboard
				expect(
					r.start_date <= '2026-10-20' && r.end_date >= '2026-10-01'
				).toBe(false);
			}
			// No crew-change day inside the blackout window
			expect(r.start_date >= '2026-08-10' && r.start_date <= '2026-08-16').toBe(false);
		}

		// The partner-blocked date surfaces as unresolved, not silently lost
		expect(smart.unresolved).toEqual([
			{ date: '2026-10-10', label: 'G-blocked', priority: 4, reason: 'partner-conflict' },
		]);
	});

	it('is deterministic — identical inputs produce identical output', () => {
		const a = generateSmartProjections(seedConfig, seedContext);
		const b = generateSmartProjections(seedConfig, seedContext);
		expect(b).toEqual(a);
	});
});
