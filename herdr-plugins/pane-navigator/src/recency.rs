//! Ctrl-Tab recency: the pure state machine behind the `observe` event hook and
//! the `toggle` hotkey. Both run it under one file lock; this module does no I/O.
//!
//! A workspace becomes the return point (`prev`) only once it has been dwelt on
//! for `DWELL_MS`, so workspaces merely passed through are skipped. A toggle
//! always commits, so rapid double Ctrl-Tab keeps flipping between two spots.

use serde_json::{Value, json};

/// Minimum stay before a departed workspace becomes the return point.
pub const DWELL_MS: u64 = 2000;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Spot {
    pub workspace: String,
    /// Exact tab to return to; `None` means the workspace's active tab.
    pub tab: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct State {
    pub cur: Option<Spot>,
    /// When `cur`'s workspace was entered (epoch ms).
    pub since_ms: u64,
    pub prev: Option<Spot>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Cause {
    Observed,
    Toggle,
}

/// Advance the state for focus landing on `to` at `now_ms`.
pub fn step(state: &State, to: Spot, now_ms: u64, cause: Cause) -> State {
    let Some(cur) = &state.cur else {
        return State {
            cur: Some(to),
            since_ms: now_ms,
            prev: None,
        };
    };
    if cur.workspace == to.workspace {
        let tab = to.tab.or_else(|| cur.tab.clone());
        return State {
            cur: Some(Spot { tab, ..to }),
            ..state.clone()
        };
    }
    // Landing back on the return point always swaps, so `prev` never equals `cur`.
    let returning = state
        .prev
        .as_ref()
        .is_some_and(|p| p.workspace == to.workspace);
    let dwelt = now_ms.saturating_sub(state.since_ms) >= DWELL_MS;
    let prev = if cause == Cause::Toggle || returning || dwelt {
        Some(cur.clone())
    } else {
        state.prev.clone()
    };
    State {
        cur: Some(to),
        since_ms: now_ms,
        prev,
    }
}

/// Sync with the live focus `active`, then pick the return point (if any).
pub fn plan_toggle(state: &State, active: Spot, now_ms: u64) -> (State, Option<Spot>) {
    let synced = step(state, active, now_ms, Cause::Observed);
    let target = synced.prev.clone();
    (synced, target)
}

fn spot_json(spot: &Option<Spot>) -> Value {
    match spot {
        Some(s) => json!({"workspace": s.workspace, "tab": s.tab}),
        None => Value::Null,
    }
}

pub fn to_json(state: &State) -> Value {
    json!({
        "cur": spot_json(&state.cur),
        "since_ms": state.since_ms,
        "prev": spot_json(&state.prev),
    })
}

/// `None` when the value is malformed; `Some(None)` when absent or null.
fn spot_from(value: Option<&Value>) -> Option<Option<Spot>> {
    match value {
        None | Some(Value::Null) => Some(None),
        Some(object @ Value::Object(_)) => {
            let workspace = object.get("workspace")?.as_str()?.to_owned();
            let tab = match object.get("tab") {
                None | Some(Value::Null) => None,
                Some(tab) => Some(tab.as_str()?.to_owned()),
            };
            Some(Some(Spot { workspace, tab }))
        }
        Some(_) => None,
    }
}

/// Lenient: unreadable or foreign content yields an empty state.
pub fn from_json(value: &Value) -> State {
    let parsed = || {
        Some(State {
            cur: spot_from(value.get("cur"))?,
            since_ms: value.get("since_ms").and_then(Value::as_u64).unwrap_or(0),
            prev: spot_from(value.get("prev"))?,
        })
    };
    parsed().unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn spot(workspace: &str, tab: &str) -> Spot {
        Spot {
            workspace: workspace.into(),
            tab: Some(tab.into()),
        }
    }

    fn observe(state: &State, workspace: &str, tab: &str, now_ms: u64) -> State {
        step(state, spot(workspace, tab), now_ms, Cause::Observed)
    }

    #[test]
    fn first_observation_sets_current_without_return_point() {
        let state = observe(&State::default(), "w1", "w1:t1", 1_000);
        assert_eq!(state.cur, Some(spot("w1", "w1:t1")));
        assert_eq!(state.since_ms, 1_000);
        assert_eq!(state.prev, None);
    }

    #[test]
    fn dwelt_workspace_becomes_return_point_with_its_exact_tab() {
        let a = observe(&State::default(), "w1", "w1:t2", 0);
        let b = observe(&a, "w2", "w2:t1", DWELL_MS);
        assert_eq!(b.prev, Some(spot("w1", "w1:t2")));
        assert_eq!(b.cur, Some(spot("w2", "w2:t1")));
        assert_eq!(b.since_ms, DWELL_MS);
    }

    #[test]
    fn workspaces_passed_through_are_skipped() {
        let a = observe(&State::default(), "w1", "w1:t1", 0);
        let b = observe(&a, "w2", "w2:t1", 10_000);
        let c = observe(&b, "w3", "w3:t1", 10_300);
        assert_eq!(c.prev, Some(spot("w1", "w1:t1")));
        assert_eq!(c.cur, Some(spot("w3", "w3:t1")));
    }

    #[test]
    fn brief_detour_back_to_return_point_swaps_them() {
        let a = observe(&State::default(), "w1", "w1:t1", 0);
        let b = observe(&a, "w2", "w2:t1", 10_000);
        let back = observe(&b, "w1", "w1:t1", 10_500);
        assert_eq!(back.prev, Some(spot("w2", "w2:t1")));
        assert_eq!(back.cur, Some(spot("w1", "w1:t1")));
    }

    #[test]
    fn toggle_commits_even_without_dwell() {
        let a = observe(&State::default(), "w1", "w1:t1", 0);
        let b = step(&a, spot("w2", "w2:t1"), 10_000, Cause::Toggle);
        let c = observe(&b, "w3", "w3:t1", 10_100);
        let d = step(&c, spot("w1", "w1:t1"), 10_200, Cause::Toggle);
        assert_eq!(d.prev, Some(spot("w3", "w3:t1")));
        assert_eq!(d.cur, Some(spot("w1", "w1:t1")));
    }

    #[test]
    fn tab_change_within_workspace_only_updates_current_tab() {
        let a = observe(&State::default(), "w1", "w1:t1", 0);
        let b = observe(&a, "w2", "w2:t1", 10_000);
        let c = observe(&b, "w2", "w2:t3", 30_000);
        assert_eq!(c.cur, Some(spot("w2", "w2:t3")));
        assert_eq!(c.since_ms, 10_000);
        assert_eq!(c.prev, Some(spot("w1", "w1:t1")));
    }

    #[test]
    fn repeated_event_is_a_no_op() {
        let a = observe(&State::default(), "w1", "w1:t1", 0);
        let b = observe(&a, "w2", "w2:t1", 10_000);
        assert_eq!(observe(&b, "w2", "w2:t1", 20_000), b);
    }

    #[test]
    fn return_point_never_equals_current_workspace() {
        let mut state = State::default();
        let path = [
            ("w1", 0),
            ("w2", 5_000),
            ("w1", 5_100),
            ("w2", 5_200),
            ("w3", 9_000),
        ];
        for (workspace, now) in path {
            state = observe(&state, workspace, &format!("{workspace}:t1"), now);
            let cur = state.cur.as_ref().map(|s| &s.workspace);
            assert_ne!(state.prev.as_ref().map(|s| &s.workspace), cur);
        }
    }

    #[test]
    fn plan_toggle_targets_return_point() {
        let a = observe(&State::default(), "w1", "w1:t2", 0);
        let b = observe(&a, "w2", "w2:t1", 10_000);
        let (synced, target) = plan_toggle(&b, spot("w2", "w2:t1"), 11_000);
        assert_eq!(synced, b);
        assert_eq!(target, Some(spot("w1", "w1:t2")));
    }

    #[test]
    fn plan_toggle_syncs_a_missed_tab_change() {
        let a = observe(&State::default(), "w1", "w1:t1", 0);
        let b = observe(&a, "w2", "w2:t1", 10_000);
        let (synced, target) = plan_toggle(&b, spot("w2", "w2:t4"), 11_000);
        assert_eq!(synced.cur, Some(spot("w2", "w2:t4")));
        assert_eq!(target, Some(spot("w1", "w1:t1")));
    }

    #[test]
    fn plan_toggle_without_history_has_no_target() {
        let (synced, target) = plan_toggle(&State::default(), spot("w1", "w1:t1"), 0);
        assert_eq!(synced.cur, Some(spot("w1", "w1:t1")));
        assert_eq!(target, None);
    }

    #[test]
    fn json_round_trips() {
        let a = observe(&State::default(), "w1", "w1:t1", 0);
        let b = step(
            &a,
            Spot {
                workspace: "w2".into(),
                tab: None,
            },
            10_000,
            Cause::Toggle,
        );
        assert_eq!(from_json(&to_json(&b)), b);
    }

    #[test]
    fn foreign_json_is_an_empty_state() {
        assert_eq!(from_json(&json!(null)), State::default());
        assert_eq!(from_json(&json!({"cur": 7, "prev": "x"})), State::default());
    }
}
