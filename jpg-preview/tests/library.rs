use jpg_preview::{delete_image, is_supported_image, render};
use std::path::Path;

#[test]
fn library_detects_paths_and_renders_positioned_kitty_stream() {
    assert!(is_supported_image(Path::new("photo.JPEG")));
    assert!(is_supported_image(Path::new("photo.PNG")));
    assert!(is_supported_image(Path::new("photo.ARW")));
    assert!(!is_supported_image(Path::new("photo.gif")));
    let path = std::env::temp_dir().join(format!("jpg-preview-lib-{}.png", std::process::id()));
    image::RgbImage::from_pixel(2, 1, image::Rgb([12, 34, 56])).save(&path).unwrap();
    let stream = render(&path, 1, 1, 7, 2).unwrap();
    std::fs::remove_file(path).unwrap();
    assert!(stream.starts_with(b"\x1b7\x1b[3;8H\x1b_Ga=T,f=100,s=1,v=1,i=424242,"));
    assert!(stream.ends_with(b"\x1b8"));
    assert_eq!(delete_image(), b"\x1b_Ga=d,d=I,i=424242,q=2\x1b\\");
    assert!(render(Path::new("/nonexistent.png"), 1, 1, 0, 0).is_err());
}
