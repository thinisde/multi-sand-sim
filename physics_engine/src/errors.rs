use wasm_bindgen::JsValue;

pub(crate) fn js_err(msg: impl Into<String>) -> JsValue {
    JsValue::from_str(&msg.into())
}
