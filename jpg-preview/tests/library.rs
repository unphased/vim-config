use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use jpg_preview::{
    delete_image, hide_image, is_supported_image, place_image, render, upload_image,
};
use std::path::Path;

fn payload(stream: &[u8]) -> Vec<u8> {
    let text = std::str::from_utf8(stream).unwrap();
    let mut encoded = String::new();
    for packet in text.split("\x1b_G").skip(1) {
        let command = packet.split_once("\x1b\\").unwrap().0;
        if let Some((_, body)) = command.split_once(';') {
            encoded.push_str(body);
        }
    }
    STANDARD.decode(encoded).unwrap()
}

#[test]
fn uploaded_pixels_are_original_resolution_and_independent_of_placement() {
    let path = std::env::temp_dir().join(format!("jpg-preview-large-{}.png", std::process::id()));
    image::RgbImage::from_pixel(3000, 1500, image::Rgb([12, 34, 56]))
        .save(&path)
        .unwrap();
    let image = upload_image(&path, 17).unwrap();
    let upload = image.stream;
    let dimensions = image.dimensions;
    assert_eq!(dimensions, (3000, 1500));
    let decoded = image::load_from_memory(&payload(&upload)).unwrap();
    assert_eq!((decoded.width(), decoded.height()), dimensions);
    let text = std::str::from_utf8(&upload).unwrap();
    assert!(text.starts_with("\x1b_Ga=t,f=100,s=3000,v=1500,i=17,q=2,"));
    assert!(!text.contains("a=p"));
    for (width, height, x, y) in [(2, 1, 0, 0), (1, 2, 7, 3), (80, 40, 0, 1)] {
        let placed = place_image(width, height, x, y, 17).unwrap();
        assert!(placed.len() < 100);
        assert!(payload(&placed).is_empty());
        let text = std::str::from_utf8(&placed).unwrap();
        assert!(text.contains(&format!("a=p,i=17,p=1,q=2,C=1,c={width},r={height}")));
        assert!(!text.contains("a=t"));
        let rendered = render(&path, width, height, x, y, 17).unwrap();
        assert!(rendered.starts_with(&upload));
        assert!(rendered.ends_with(&placed));
    }
    std::fs::remove_file(path).unwrap();
}

#[test]
fn library_validates_placement_and_distinguishes_hide_from_free() {
    assert!(is_supported_image(Path::new("photo.JPEG")));
    assert!(is_supported_image(Path::new("photo.PNG")));
    assert!(is_supported_image(Path::new("photo.ARW")));
    assert!(!is_supported_image(Path::new("photo.gif")));
    for id in [17, 99] {
        let stream = place_image(3, 4, 7, 2, id).unwrap();
        let text = String::from_utf8(stream).unwrap();
        assert!(text.starts_with(&format!(
            "\x1b7\x1b[3;8H\x1b_Ga=p,i={id},p=1,q=2,C=1,c=3,r=4"
        )));
        assert!(text.ends_with("\x1b8"));
        assert_eq!(
            hide_image(id),
            format!("\x1b_Ga=d,d=i,i={id},q=2\x1b\\").as_bytes()
        );
        assert_eq!(
            delete_image(id),
            format!("\x1b_Ga=d,d=I,i={id},q=2\x1b\\").as_bytes()
        );
    }
    for (w, h, x, y, id) in [
        (0, 1, 0, 0, 1),
        (1, 0, 0, 0, 1),
        (1, 1, 0, 0, 0),
        (1, 1, usize::MAX, 0, 1),
        (1, 1, 0, usize::MAX, 1),
    ] {
        assert!(place_image(w, h, x, y, id).is_err());
    }
    assert!(std::panic::catch_unwind(|| delete_image(0)).is_err());
    assert!(std::panic::catch_unwind(|| hide_image(0)).is_err());
    assert!(upload_image(Path::new("/nonexistent.png"), 1).is_err());
    assert!(upload_image(Path::new("/nonexistent.png"), 0).is_err());
}
