#pragma once
#include <uxtheme.h>
#pragma comment(lib, "uxtheme.lib")
// GDI presentation only: no changes to video clocks, buffers or swap chains.
namespace studio_player_ui {
inline int px(HWND window, int value) { return MulDiv(value, GetDpiForWindow(window), 96); }
inline HBRUSH background() {
    static HBRUSH brush = CreateSolidBrush(RGB(30, 31, 34));
    return brush;
}
inline int rows(HWND window, int width) { return width < px(window, 1120) ? 2 : 1; }
inline int height(HWND window, int width) { return px(window, rows(window, width) == 2 ? 148 : 102); }
inline void button(const DRAWITEMSTRUCT &item) {
    const bool primary = item.CtlID == 1003; // Play/pause is the visual anchor.
    const bool pressed = (item.itemState & ODS_SELECTED) != 0;
    const bool focused = (item.itemState & ODS_FOCUS) != 0;
    const COLORREF fill = primary ? RGB(114, 152, 196) : pressed ? RGB(60, 63, 69) : RGB(48, 50, 55);
    HBRUSH brush = CreateSolidBrush(fill);
    HPEN pen = CreatePen(PS_SOLID, focused ? 2 : 1, primary ? RGB(114, 152, 196) : RGB(76, 79, 87));
    HGDIOBJ oldBrush = SelectObject(item.hDC, brush), oldPen = SelectObject(item.hDC, pen);
    RECT rect = item.rcItem;
    FillRect(item.hDC, &rect, background());
    RoundRect(item.hDC, rect.left + 1, rect.top + 1, rect.right - 1, rect.bottom - 1, 6, 6);
    SetBkMode(item.hDC, TRANSPARENT);
    SetTextColor(item.hDC, primary ? RGB(255, 255, 255) : RGB(225, 227, 233));
    wchar_t label[96] = {};
    GetWindowTextW(item.hwndItem, label, 96);
    HFONT font = reinterpret_cast<HFONT>(SendMessageW(item.hwndItem, WM_GETFONT, 0, 0));
    HGDIOBJ oldFont = SelectObject(item.hDC, font);
    InflateRect(&rect, -5, -2);
    DrawTextW(item.hDC, label, -1, &rect, DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS);
    SelectObject(item.hDC, oldFont); SelectObject(item.hDC, oldPen); SelectObject(item.hDC, oldBrush);
    DeleteObject(pen); DeleteObject(brush);
}
inline LRESULT track(const NMCUSTOMDRAW &draw) {
    if (draw.dwDrawStage == CDDS_PREPAINT) return CDRF_NOTIFYITEMDRAW;
    if (draw.dwDrawStage != CDDS_ITEMPREPAINT) return CDRF_DODEFAULT;
    if (draw.dwItemSpec == TBCD_CHANNEL) {
        RECT rect = draw.rc;
        rect.top = (rect.top + rect.bottom) / 2 - 2; rect.bottom = rect.top + 4;
        HBRUSH brush = CreateSolidBrush(RGB(75, 78, 85));
        FillRect(draw.hdc, &rect, brush); DeleteObject(brush);
        const LRESULT value = SendMessageW(draw.hdr.hwndFrom, TBM_GETPOS, 0, 0);
        rect.right = rect.left + static_cast<LONG>((rect.right - rect.left) * value / 10000);
        brush = CreateSolidBrush(RGB(114, 152, 196));
        FillRect(draw.hdc, &rect, brush); DeleteObject(brush);
        return CDRF_SKIPDEFAULT;
    }
    if (draw.dwItemSpec == TBCD_THUMB) {
        HBRUSH brush = CreateSolidBrush(RGB(225, 228, 235));
        HGDIOBJ old = SelectObject(draw.hdc, brush), pen = SelectObject(draw.hdc, GetStockObject(NULL_PEN));
        Ellipse(draw.hdc, draw.rc.left, draw.rc.top + 3, draw.rc.right, draw.rc.bottom - 3);
        SelectObject(draw.hdc, pen); SelectObject(draw.hdc, old); DeleteObject(brush);
        return CDRF_SKIPDEFAULT;
    }
    return CDRF_DODEFAULT;
}
}
