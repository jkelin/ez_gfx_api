[__AttributeUsage(_AttributeTargets.Var)]
struct VertexHeapAttribute
{
    string name;
};

[__AttributeUsage(_AttributeTargets.Var)]
struct ColorTargetAttribute
{
    string name;
    string access;
};

[__AttributeUsage(_AttributeTargets.Function)]
struct DepthTargetAttribute
{
    string name;
    string access;
};

[__AttributeUsage(_AttributeTargets.Var)]
struct RelativeScaleAttribute
{
    float value;
};

[__AttributeUsage(_AttributeTargets.Var)]
struct TargetLayoutAttribute
{
    string kind;
    string format;
};

[__AttributeUsage(_AttributeTargets.Var)]
struct LoadTargetAttribute
{
};
