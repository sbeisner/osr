using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using Newtonsoft.Json;

namespace osr_dotnet.Controllers
{
    using osr_dotnet.Models;

    /// <summary>
    /// Local file-backed user store. Replaces the original CosmosController so
    /// the app can run with no cloud dependency. Users persist as JSON at
    /// %LOCALAPPDATA%\osr\users.json. Public surface matches what the WPF
    /// pages already call so the rest of the UI did not have to change.
    /// </summary>
    public class LocalUserStore
    {
        private readonly string _path;
        private readonly object _lock = new object();
        private List<User> _users = new List<User>();

        public LocalUserStore()
        {
            string dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "osr");
            Directory.CreateDirectory(dir);
            _path = Path.Combine(dir, "users.json");
        }

        public async Task startAsync()
        {
            if (!File.Exists(_path))
            {
                return;
            }

            string json;
            using (var reader = new StreamReader(_path))
            {
                json = await reader.ReadToEndAsync();
            }
            if (string.IsNullOrWhiteSpace(json))
            {
                return;
            }

            var loaded = JsonConvert.DeserializeObject<List<User>>(json);
            if (loaded != null)
            {
                lock (_lock) { _users = loaded; }
            }
        }

        public async Task AddUsersToContainerAsync(User user)
        {
            bool conflict;
            lock (_lock)
            {
                conflict = _users.Any(u =>
                    u.Id == user.Id ||
                    string.Equals(u.Email, user.Email, StringComparison.OrdinalIgnoreCase));
                if (!conflict)
                {
                    _users.Add(user);
                }
            }

            if (conflict)
            {
                Console.WriteLine("User with id {0} or email {1} already exists", user.Id, user.Email);
                return;
            }

            await SaveAsync();
        }

        public async Task UpdateUser(User user)
        {
            lock (_lock)
            {
                int idx = _users.FindIndex(u => u.Id == user.Id);
                if (idx >= 0)
                {
                    _users[idx] = user;
                }
                else
                {
                    _users.Add(user);
                }
            }
            await SaveAsync();
        }

        public async Task<User> QueryUsersAsync(string email, string password)
        {
            // Passwords are bcrypt-hashed on AccountCreate (see User.Password
            // setter call in AccountCreate.Save_Account_To_DB). For users that
            // predate the hashing change, their stored Password is plaintext;
            // we detect that case (no leading "$2" prefix), do a plaintext
            // compare, and on a match re-hash and persist so the next login
            // is on the new path. One-time per legacy user.
            User match;
            bool needsMigration = false;
            lock (_lock)
            {
                var candidates = _users.Where(u =>
                    string.Equals(u.Email, email, StringComparison.OrdinalIgnoreCase)).ToList();

                if (candidates.Count == 0)
                {
                    return null;
                }
                if (candidates.Count > 1)
                {
                    Console.WriteLine("Error: multiple users match email " + email);
                    return null;
                }

                match = candidates[0];

                bool ok;
                bool isBcryptHash = !string.IsNullOrEmpty(match.Password)
                                    && match.Password.StartsWith("$2");
                if (isBcryptHash)
                {
                    try { ok = BCrypt.Net.BCrypt.Verify(password, match.Password); }
                    catch { ok = false; }
                }
                else
                {
                    ok = (match.Password == password);
                    needsMigration = ok;
                }

                if (!ok)
                {
                    return null;
                }
            }

            if (needsMigration)
            {
                match.Password = BCrypt.Net.BCrypt.HashPassword(password);
                await UpdateUser(match);
            }
            return match;
        }

        private async Task SaveAsync()
        {
            string json;
            lock (_lock)
            {
                json = JsonConvert.SerializeObject(_users, Formatting.Indented);
            }

            // Write to a sibling temp file then move into place, so a crash
            // mid-write cannot leave users.json half-written.
            string tmp = _path + ".tmp";
            using (var writer = new StreamWriter(tmp, false))
            {
                await writer.WriteAsync(json);
            }
            if (File.Exists(_path))
            {
                File.Delete(_path);
            }
            File.Move(tmp, _path);
        }
    }
}
