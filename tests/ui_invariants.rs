use rackglass::{
    capture::letterbox,
    prom::client::PromPoint,
    ui::{
        chart::segments,
        history::RequestGuard,
        scene::{COLUMNS, column_boxes, header_boxes},
    },
};

#[test]
fn headings_span_the_same_columns_as_cells() {
    for width in [996.0, 1100.0] {
        let cells = column_boxes(width);
        let headings = header_boxes(width);
        for ((title, left, width), (index, column)) in headings.iter().zip(
            COLUMNS
                .iter()
                .enumerate()
                .filter(|(_, c)| !c.heading.is_empty()),
        ) {
            assert_eq!(*title, column.heading);
            assert_eq!(*left, cells[index].0);
            let last = cells[index + column.span - 1];
            assert!((left + width - last.0 - last.1).abs() < 0.001);
        }
        let last = cells.last().unwrap();
        assert!((last.0 + last.1 - (width - 14.0)).abs() < 0.001);
        assert!(cells.windows(2).all(|p| p[0].0 + p[0].1 <= p[1].0));
    }
}

#[test]
fn chart_breaks_an_outage_but_tolerates_scrape_jitter() {
    let points: Vec<_> = [0., 15., 34., 100., 115.]
        .into_iter()
        .map(|t| PromPoint { t, v: 50. })
        .collect();
    let runs = segments(&points, 3600);
    assert_eq!(runs.iter().map(|s| s.len()).collect::<Vec<_>>(), [3, 2]);
    assert_eq!(runs[1][0].t, 100.);
}

#[test]
fn letterbox_contains_the_entire_source() {
    for (source, viewport) in [((1920, 1080), (1024., 600.)), ((600, 1024), (1004., 452.))] {
        let (x, y, width, height) = letterbox(source, viewport);
        assert!(x >= 0. && y >= 0.);
        assert!((2. * x + width - viewport.0).abs() < 0.001);
        assert!((2. * y + height - viewport.1).abs() < 0.001);
        assert!((width / height - source.0 as f32 / source.1 as f32).abs() < 0.001);
    }
    assert_eq!(letterbox((0, 0), (1024., 600.)), (0., 0., 0., 0.));
}

#[test]
fn graph_window_changes_and_node_selection_reject_stale_completions() {
    for (first, replacement) in [("900", "3600"), ("pve-host", "vm-node-1")] {
        let mut guard = RequestGuard::default();
        assert!(guard.begin(first.into()).is_none());
        guard.activate();
        let old = guard.begin(first.into()).unwrap();
        let current = guard.begin(replacement.into()).unwrap();
        assert!(!guard.finish(&old));
        assert!(
            guard.loading,
            "a stale error must not clear the current spinner"
        );
        assert!(guard.finish(&current));
        assert!(!guard.loading);
        let hidden = guard.begin(replacement.into()).unwrap();
        guard.deactivate();
        assert!(!guard.accepts(&hidden));
        guard.activate();
        let visible = guard.begin(replacement.into()).unwrap();
        assert!(
            !guard.finish(&hidden),
            "same key after reactivation is a new request"
        );
        assert!(guard.finish(&visible));
    }
}

#[test]
fn sync_edits_rows_in_place_and_installs_only_the_first_model() {
    use rackglass::ui::scene::sync;
    use slint::{Model, ModelRc, VecModel};
    use std::rc::Rc;

    let rows = Rc::new(VecModel::from(vec![1, 2, 3]));
    let current: ModelRc<i32> = rows.clone().into();
    let mut replaced = false;
    sync(current.clone(), vec![1, 9, 3, 4], |_| replaced = true);
    assert_eq!(rows.iter().collect::<Vec<_>>(), [1, 9, 3, 4]);
    sync(current, vec![5], |_| replaced = true);
    assert_eq!(rows.iter().collect::<Vec<_>>(), [5]);
    assert!(!replaced, "an installed VecModel is edited, never replaced");

    let mut installed = None;
    sync(ModelRc::default(), vec![7], |m| installed = Some(m));
    let installed = installed.expect("the first call installs a model");
    assert_eq!(installed.iter().collect::<Vec<_>>(), [7]);
}

#[test]
fn identical_text_items_compare_the_same_despite_their_empty_images() {
    use rackglass::ui::scene::{Scene, same_ink};
    let build = |text: &str| {
        let mut s = Scene::default();
        s.text(10., 20., 100., text, 16., 0xffffff, 500);
        s.0.remove(0)
    };
    // The derived PartialEq says no here, which once made every poll rewrite
    // every row.
    assert!(build("42%") != build("42%"));
    assert!(same_ink(&build("42%"), &build("42%")));
    assert!(!same_ink(&build("42%"), &build("43%")));
}
