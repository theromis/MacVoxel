use std::collections::HashMap;

use super::*;

#[test]
fn rejects_a_cycle_and_a_duplicate_name() {
    let mut skeleton = Skeleton::default();
    skeleton.add("hips", None, [0.0, 0.0, 0.0], None).unwrap();
    skeleton
        .add("leg", Some("hips"), [0.0, 1.0, 0.0], None)
        .unwrap();
    let err = skeleton
        .set("hips", Some(Some("leg".into())), None, None, None)
        .unwrap_err();
    assert!(err.contains("leg"), "{err}");
    let err = skeleton
        .add("leg", Some("hips"), [0.0; 3], None)
        .unwrap_err();
    assert!(err.contains("leg"), "{err}");
}

#[test]
fn chunk_round_trips_and_rejects_an_unknown_version() {
    let mut skeleton = Skeleton::default();
    skeleton.add("hips", None, [0.5, 1.5, 0.0], None).unwrap();
    skeleton
        .add(
            "leg",
            Some("hips"),
            [0.5, 0.0, 0.0],
            Some(IDENTITY_ROTATION),
        )
        .unwrap();
    let objects = [
        ObjectRef {
            trn: -1,
            name: "Body",
            bone: Some("hips"),
        },
        ObjectRef {
            trn: -1,
            name: "Leg",
            bone: Some("leg"),
        },
    ];
    let body = encode_chunk(&objects, &skeleton).unwrap().unwrap();
    let (loaded, binds) = decode_chunk(&body).unwrap();
    assert_eq!(loaded, skeleton);
    assert_eq!(binds[1].bone, "leg");
    let assigned = assign_bones(&[(-1, "Body"), (-1, "Leg")], &binds, &loaded).unwrap();
    assert_eq!(assigned[0].as_deref(), Some("hips"));
    assert_eq!(assigned[1].as_deref(), Some("leg"));
    let mut bad = body.clone();
    bad[0] = 99;
    let err = decode_chunk(&bad).unwrap_err();
    assert!(err.contains("version 99"), "{err}");
}

#[test]
fn identity_pose_puts_the_joint_on_the_pivot() {
    let mut skeleton = Skeleton::default();
    skeleton.add("hips", None, [1.0, 2.0, 3.0], None).unwrap();
    let pose = bind_pose(&skeleton).unwrap();
    assert!((pose[0].translation[0] - 1.0).abs() < 1e-5);
    assert!((pose[0].translation[1] - 3.0).abs() < 1e-5);
    assert!((pose[0].translation[2] - -2.0).abs() < 1e-5);
    let inverse = Mat4::from_cols_array(&pose[0].inverse_bind);
    let world = Mat4::from_translation(Vec3::new(1.0, 3.0, -2.0));
    let point = Vec3::new(4.0, 3.0, -2.0);
    let skinned = world.transform_point3(inverse.transform_point3(point));
    assert!((skinned - point).length() < 1e-4);
}

#[test]
fn a_parent_pose_orbits_the_child_and_identity_is_a_no_op() {
    let mut skeleton = Skeleton::default();
    skeleton.add("root", None, [0.0, 0.0, 0.0], None).unwrap();
    skeleton
        .add("child", Some("root"), [2.0, 0.0, 0.0], None)
        .unwrap();
    let rest = skin_deltas(&skeleton, &HashMap::new()).unwrap();
    let point = Vec3::new(3.0, 1.0, 2.0);
    for delta in &rest {
        let moved = delta.transform_point3(point);
        assert!((moved - point).length() < 1e-4, "{moved}");
    }
    let half = std::f32::consts::FRAC_PI_2 * 0.5;
    let mut pose = HashMap::new();
    pose.insert("root".into(), [0.0, 0.0, half.sin(), half.cos()]);
    let joints = posed_joints(&skeleton, &pose).unwrap();
    assert!(joints[1].0.x.abs() < 1e-4, "{}", joints[1].0);
    assert!((joints[1].0.y - 2.0).abs() < 1e-4, "{}", joints[1].0);
    assert!(joints[1].0.z.abs() < 1e-4, "{}", joints[1].0);
}

#[test]
fn clips_round_trip_through_the_mvan_body() {
    let clip = Clip {
        name: "wave".into(),
        tracks: vec![BoneTrack {
            bone: "root".into(),
            keys: vec![ClipKey {
                time: 0.25,
                rotation: IDENTITY_ROTATION,
                translation: [1.0, 2.0, 3.0],
                scale: [1.0, 1.0, 2.0],
            }],
        }],
    };
    let body = encode_clips(&[clip.clone()]).unwrap().unwrap();
    assert_eq!(decode_clips(&body).unwrap(), vec![clip]);
    assert!(encode_clips(&[]).unwrap().is_none());
}
