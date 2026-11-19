using System.Security.Cryptography;

namespace CinegyBridge.Web.Accounts;

/// <summary>PBKDF2-SHA256 from the framework; nothing hand-rolled.</summary>
public static class PasswordHasher
{
    // OWASP's 2023 figure for PBKDF2-HMAC-SHA256.
    public const int Iterations = 600_000;
    private const int SaltBytes = 16;
    private const int HashBytes = 32;

    public const int MinimumLength = 10;
    public const int MaximumLength = 128;

    public static PasswordHash Hash(string password)
    {
        var salt = RandomNumberGenerator.GetBytes(SaltBytes);
        var hash = Rfc2898DeriveBytes.Pbkdf2(password, salt, Iterations, HashAlgorithmName.SHA256, HashBytes);
        return new PasswordHash(Convert.ToBase64String(hash), Convert.ToBase64String(salt), Iterations);
    }

    public static bool Verify(string password, PasswordHash stored)
    {
        var salt = Convert.FromBase64String(stored.Salt);
        var expected = Convert.FromBase64String(stored.Hash);
        var actual = Rfc2898DeriveBytes.Pbkdf2(password, salt, stored.Iterations, HashAlgorithmName.SHA256, expected.Length);
        return CryptographicOperations.FixedTimeEquals(actual, expected);
    }

    /// <summary>Spends the same time as a real check, so an unknown username
    /// cannot be told apart from a wrong password by the clock.</summary>
    public static void VerifyDummy(string password) => Verify(password, Dummy.Value);

    private static readonly Lazy<PasswordHash> Dummy = new(() => Hash("dummy-password-for-timing"));

    public static string? Validate(string? password) => password switch
    {
        null => "password_required",
        { Length: < MinimumLength } => "password_too_short",
        { Length: > MaximumLength } => "password_too_long",
        _ => null,
    };
}

public sealed record PasswordHash(string Hash, string Salt, int Iterations);
