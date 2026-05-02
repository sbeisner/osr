using System;
using System.Collections.Generic;
using System.Configuration;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using Microsoft.Azure.Cosmos;

namespace osr_dotnet.Controllers
{
    using osr_dotnet.Models;
    using System.Net;

    public class CosmosController
    {
        private readonly string EndpointUrl;
        private readonly string PrimaryKey;

        private CosmosClient cosmosClient;
        private Database database;
        private Container container;

        private string databaseId = "UsersDatabase";
        private string containerId = "UsersContainer";

        public CosmosController()
        {
            EndpointUrl = ConfigurationManager.AppSettings["Cosmos:Endpoint"];
            PrimaryKey = ConfigurationManager.AppSettings["Cosmos:Key"];

            if (string.IsNullOrWhiteSpace(EndpointUrl) || string.IsNullOrWhiteSpace(PrimaryKey)
                || PrimaryKey == "REPLACE_WITH_YOUR_COSMOS_PRIMARY_KEY")
            {
                throw new InvalidOperationException(
                    "Cosmos DB credentials are not configured. Set Cosmos:Endpoint and Cosmos:Key " +
                    "in App.config <appSettings>. See README.md for setup instructions.");
            }
        }

        public async Task startAsync()
        {
            this.cosmosClient = new CosmosClient(EndpointUrl, PrimaryKey);
            await this.CreateDatabaseAsync();
            await this.CreateUserContainerAsync();
        }

        private async Task CreateDatabaseAsync()
        {
            this.database = await this.cosmosClient.CreateDatabaseIfNotExistsAsync(databaseId);
            Console.WriteLine("Created Database: {0}\n", this.database.Id);
        }

        private async Task CreateUserContainerAsync()
        {
            this.container = await this.database.CreateContainerIfNotExistsAsync(containerId, "/id");
            Console.WriteLine("Successfully created User Container");
        }

        public async Task AddUsersToContainerAsync(User user)
        {
            try
            {
                ItemResponse<User> userResponse = await this.container.CreateItemAsync<User>(user, new PartitionKey(user.Id));

                Console.WriteLine("Created item in database with id: {0} Operation consumed {1} RUs.\n", userResponse.Resource.Id, userResponse.RequestCharge);
            }
            catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.Conflict)
            {
                Console.WriteLine("Item in database with id: {0} already exists\n", user.Id);
            }
        }

        public async Task UpdateUser(User user)
        {
            try
            {
                ItemResponse<User> userResponse = await this.container.UpsertItemAsync<User>(user, new PartitionKey(user.Id));

                Console.WriteLine("Updated item in databse with id: {0}. Operation consumed {1} Rus.\n", userResponse.Resource.Id, userResponse.RequestCharge);
            }
            catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.Conflict)
            {
                Console.WriteLine("Item in database with id: {0} already exists\n", user.Id);
            }
        }

        public async Task<User> QueryUsersAsync(string email, string password)
        {
            // TODO(handoff): passwords are stored in plaintext in Cosmos. Hash on
            // create + on lookup before re-enabling this for any real users.
            QueryDefinition queryDefinition = new QueryDefinition(
                    "SELECT * FROM c WHERE c.email = @email AND c.password = @password")
                .WithParameter("@email", email)
                .WithParameter("@password", password);

            FeedIterator<User> queryResultSetIterator = this.container.GetItemQueryIterator<User>(queryDefinition);

            List<User> users = new List<User>();

            while (queryResultSetIterator.HasMoreResults)
            {
                FeedResponse<User> currentResultSet = await queryResultSetIterator.ReadNextAsync();
                foreach (User user in currentResultSet)
                {
                    users.Add(user);
                }
            }

            if (users.Count > 1)
            {
                Console.WriteLine("Error: Multiple users match search\n");
                return null;
            }
            else if (users.Count == 0)
            {
                return null;
            }
            else
            {
                return users.ElementAt(0);
            }
        }
    }
}
