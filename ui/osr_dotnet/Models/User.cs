namespace osr_dotnet.Models
{
    using Newtonsoft.Json;

    public class User
    {
        [JsonProperty(PropertyName = "id")]
        public string Id { get; set; }

        [JsonProperty(PropertyName = "email")]
        public string Email { get; set; }

        [JsonProperty(PropertyName = "fullName")]
        public string Name { get; set; }

        [JsonProperty(PropertyName = "password")]
        public string Password { get; set; }

        [JsonProperty(PropertyName = "dateLicenseIssued")]
        public string DateLicenseIssued { get; set; }

        [JsonProperty(PropertyName = "dateLicenseExpires")]
        public string DateLicenseExpires { get; set; }

        [JsonProperty(PropertyName = "trackedDir")]
        public string TrackedDir { get; set; }

        [JsonProperty(PropertyName = "whitelist")]
        public string Whitelist { get; set; }

        [JsonProperty(PropertyName = "isInitialized")]
        public string IsInitialized { get; set; }
    }
}
