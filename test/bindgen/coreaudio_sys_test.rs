use coreaudio_sys::{AudioComponentCount, AudioComponentDescription};

#[test]
fn coreaudio_sys() {
    // A zeroed descriptor is a wildcard that matches every registered
    // component, so this exercises the generated struct layout and links
    // against the real AudioToolbox framework.
    let desc = AudioComponentDescription::default();
    let count = unsafe { AudioComponentCount(&desc) };
    assert!(count > 0);
}
