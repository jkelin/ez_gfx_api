namespace EzGfx.Examples;

internal static class Program
{
    private static int Main(string[] args)
    {
        try
        {
            ParsedArguments parsed = ParsedArguments.Parse(args);
            string screenshot = parsed.ScreenshotPath ?? Path.Combine(
                ExampleHost.RepositoryRoot,
                "artifacts",
                "csharp",
                $"Example{parsed.Example:00}.png");
            ExampleOptions options = new(parsed.Frames, screenshot, parsed.Hidden, parsed.EnableValidation);
            switch (parsed.Example)
            {
                case 1:
                    Example01.Run(options);
                    break;
                case 2:
                    Example02.Run(options);
                    break;
                case 3:
                    Example03.Run(options);
                    break;
                case 4:
                    Example04.Run(options);
                    break;
                case 5:
                    Example05.Run(options);
                    break;
                case 6:
                    Example06.Run(options);
                    break;
                default:
                    throw new ArgumentOutOfRangeException(nameof(parsed.Example), "Example must be between 1 and 6.");
            }
            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine(error);
            return 1;
        }
    }

    private sealed record ParsedArguments(int Example, int Frames, string? ScreenshotPath, bool Hidden, bool EnableValidation)
    {
        public static ParsedArguments Parse(string[] args)
        {
            int example = 1;
            int frames = 1;
            string? screenshot = null;
            bool hidden = true;
            bool validation = true;
            for (int index = 0; index < args.Length; index++)
            {
                switch (args[index])
                {
                    case "--example":
                        example = ParsePositive(args, ref index, "example");
                        break;
                    case "--frames":
                        frames = ParsePositive(args, ref index, "frames");
                        break;
                    case "--screenshot":
                        screenshot = NextValue(args, ref index, "screenshot");
                        break;
                    case "--visible":
                        hidden = false;
                        break;
                    case "--no-validation":
                        validation = false;
                        break;
                    case "--help":
                        throw new ArgumentException("Usage: --example 1..6 [--frames N] [--screenshot path] [--visible] [--no-validation]");
                    default:
                        throw new ArgumentException($"Unknown argument: {args[index]}");
                }
            }
            return new ParsedArguments(example, frames, screenshot, hidden, validation);
        }

        private static int ParsePositive(string[] args, ref int index, string name)
        {
            string value = NextValue(args, ref index, name);
            if (!int.TryParse(value, out int parsed) || parsed <= 0)
            {
                throw new ArgumentException($"{name} must be a positive integer.");
            }
            return parsed;
        }

        private static string NextValue(string[] args, ref int index, string name)
        {
            if (++index >= args.Length || string.IsNullOrWhiteSpace(args[index]))
            {
                throw new ArgumentException($"Missing value for {name}.");
            }
            return args[index];
        }
    }
}
