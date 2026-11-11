use jpg_preview::{delete_image, is_supported_image, render};
use std::path::Path;

#[test]
fn library_renders_cell_bounded_placements_with_caller_ids() {
    assert!(is_supported_image(Path::new("photo.JPEG")));
    assert!(is_supported_image(Path::new("photo.PNG")));
    assert!(is_supported_image(Path::new("photo.ARW")));
    assert!(!is_supported_image(Path::new("photo.gif")));
    let path = std::env::temp_dir().join(format!("jpg-preview-lib-{}.png", std::process::id()));
    image::RgbImage::from_pixel(20, 10, image::Rgb([12, 34, 56]))
        .save(&path)
        .unwrap();
    for (id, width, height) in [(17, 3, 4), (99, 1, 2)] {
        let stream = render(&path, width, height, 7, 2, id).unwrap();
        let text = String::from_utf8(stream).unwrap();
        assert!(text.starts_with(&format!(
            "\x1b7\x1b[3;8H\x1b_Ga=T,f=100,s=20,v=10,i={id},q=2,C=1,c={width},r={height},"
        )));
        assert!(text.ends_with("\x1b8"));
        assert_eq!(
            delete_image(id),
            format!("\x1b_Ga=d,d=I,i={id},q=2\x1b\\").as_bytes()
        );
    }
    assert!(render(&path, 0, 1, 0, 0, 1).is_err());
    assert!(render(&path, 1, 0, 0, 0, 1).is_err());
    assert!(render(&path, 1, 1, 0, 0, 0).is_err());
    assert!(std::panic::catch_unwind(|| delete_image(0)).is_err());
    assert!(render(&path, 1, 1, usize::MAX, 0, 1).is_err());
    std::fs::remove_file(path).unwrap();
    assert!(render(Path::new("/nonexistent.png"), 1, 1, 0, 0, 1).is_err());
}
