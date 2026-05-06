use jni::objects::{JClass, JString};
use jni::sys::{jint, jlong, jobject};
use jni::JNIEnv;
use std::collections::HashMap;
use std::sync::Mutex;

struct WatcherWrapper {
    watch_descriptors: Mutex<HashMap<String, String>>,
}

impl WatcherWrapper {
    fn new() -> Self {
        Self {
            watch_descriptors: Mutex::new(HashMap::new()),
        }
    }
}

#[no_mangle]
pub extern "system" fn Java_com_jetbrains_analyzer_filewatcher_FileWatcher_create(_env: JNIEnv, _class: JClass) -> jlong {
    let wrapper = Box::new(WatcherWrapper::new());
    Box::into_raw(wrapper) as jlong
}
