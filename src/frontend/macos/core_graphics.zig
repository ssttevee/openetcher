pub const Point = extern struct {
    x: f64,
    y: f64,

    pub const zero = .{ .x = 0, .y = 0 };
};

pub const Size = extern struct {
    width: f64,
    height: f64,
};

pub const Rect = extern struct {
    origin: Point,
    size: Size,
};
