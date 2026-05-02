using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using DiscUtils;
using DiscUtils.Iso9660;

namespace osr_dotnet.Controllers
{
    class DiscUtilsController
    {
        long diskSize;
        CDBuilder builder;

        public DiscUtilsController()
        {
            
        }

        public void firstTimeInit()
        {
            builder = new CDBuilder();
            builder.UseJoliet = true;
            builder.VolumeIdentifier = "CLEAN_DISK";
        }


    }
}
