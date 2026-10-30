"""Finder layout for the drag-to-Applications installer (no Finder automation)."""

files = [(defines["app"], "MovemberCam.app")]
symlinks = {"Applications": "/Applications"}
background = defines["background"]
format = "UDZO"
filesystem = "HFS+"
window_rect = ((160, 160), (760, 480))
default_view = "icon-view"
include_icon_view_settings = True
include_list_view_settings = False
show_status_bar = False
show_toolbar = False
show_tab_view = False
show_pathbar = False
show_sidebar = False
arrange_by = None
icon_size = 112
text_size = 14
label_pos = "bottom"
icon_locations = {"MovemberCam.app": (170, 240), "Applications": (590, 240)}
