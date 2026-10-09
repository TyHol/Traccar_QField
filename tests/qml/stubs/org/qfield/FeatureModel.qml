import QtQuick
// Stand-in for QField's FeatureModel: Field role (Qt.UserRole + 3) → {type}
QtObject {
    property var currentLayer: null
    function index(row, col) { return row }
    function data(idx, role) {
        if (role !== 0x0100 + 3 || !currentLayer) return null
        return { type: currentLayer._types[idx] }
    }
}
