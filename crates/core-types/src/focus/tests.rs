use super::*;
use std::collections::BTreeMap;

#[test]
fn test_focus_query_json_contract_roundtrip() {
    let req = FocusQueryRequest {
        query: FocusQuery {
            entity: FocusEntity::Tracks,
            predicates: vec![
                FocusPredicate {
                    facet: FocusFacet::Format,
                    value: FocusValue::String {
                        value: "flac".into(),
                    },
                    mode: FocusPredicateMode::Include,
                },
                FocusPredicate {
                    facet: FocusFacet::BitDepth,
                    value: FocusValue::Int { value: 24 },
                    mode: FocusPredicateMode::Exclude,
                },
                FocusPredicate {
                    facet: FocusFacet::ReleaseYear,
                    value: FocusValue::IntRange {
                        min: Some(1970),
                        max: Some(1979),
                    },
                    mode: FocusPredicateMode::Include,
                },
                FocusPredicate {
                    facet: FocusFacet::AddedAt,
                    value: FocusValue::DateRange {
                        from: Some("2026-01-01".into()),
                        to: None,
                    },
                    mode: FocusPredicateMode::Include,
                },
            ],
            sort: Some(FocusSort {
                field: FocusSortField::SampleRate,
                direction: FocusSortDirection::Desc,
                seed: Some(42),
            }),
            include_hidden: true,
            profile_id: Some("prof-1".into()),
        },
        limit: 50,
        offset: 25,
    };

    let json = serde_json::to_value(&req).unwrap();
    assert_eq!(json["query"]["entity"], "tracks");
    assert_eq!(json["query"]["predicates"][0]["facet"], "format");
    assert_eq!(json["query"]["predicates"][0]["value"]["kind"], "string");
    assert_eq!(json["query"]["predicates"][0]["value"]["value"], "flac");
    assert_eq!(json["query"]["predicates"][1]["facet"], "bit_depth");
    assert_eq!(json["query"]["predicates"][1]["mode"], "exclude");
    assert_eq!(json["query"]["predicates"][1]["value"]["kind"], "int");
    assert_eq!(json["query"]["predicates"][2]["value"]["kind"], "int_range");
    assert_eq!(
        json["query"]["predicates"][3]["value"]["kind"],
        "date_range"
    );
    assert_eq!(json["query"]["sort"]["field"], "sample_rate");
    assert_eq!(json["query"]["sort"]["direction"], "desc");

    let decoded: FocusQueryRequest = serde_json::from_value(json).unwrap();
    assert_eq!(decoded, req);
}

#[test]
fn test_focus_defaults_and_facets_response() {
    let req: FocusQueryRequest = serde_json::from_str("{}").unwrap();
    assert_eq!(req.limit, 100);
    assert_eq!(req.offset, 0);
    assert_eq!(req.query.entity, FocusEntity::Albums);
    assert!(req.query.predicates.is_empty());

    let mut facets = BTreeMap::new();
    facets.insert(
        FocusFacet::Format.as_str().to_string(),
        vec![FocusFacetBucket {
            value: "flac".into(),
            label: "FLAC".into(),
            count: 12,
        }],
    );
    let resp = FocusFacetsResponse {
        total_matched: 12,
        facets,
        year_range: FocusIntRangeBounds {
            min: Some(1969),
            max: Some(2025),
        },
    };
    let encoded = serde_json::to_string(&resp).unwrap();
    let decoded: FocusFacetsResponse = serde_json::from_str(&encoded).unwrap();
    assert_eq!(decoded, resp);
}

#[test]
fn test_focus_preference_facet_roundtrip() {
    assert_eq!(FocusFacet::ALL.len(), 13);
    assert_eq!(FocusFacet::Preference.as_str(), "preference");
    assert_eq!(
        "preference".parse::<FocusFacet>().unwrap(),
        FocusFacet::Preference
    );
    let pred = FocusPredicate {
        facet: FocusFacet::Preference,
        value: FocusValue::String {
            value: "favorite".into(),
        },
        mode: FocusPredicateMode::Include,
    };
    let val = serde_json::to_value(&pred).unwrap();
    assert_eq!(val["facet"], "preference");
    assert_eq!(serde_json::from_value::<FocusPredicate>(val).unwrap(), pred);
}
