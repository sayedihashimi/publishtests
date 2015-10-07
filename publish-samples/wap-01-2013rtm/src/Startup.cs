using Microsoft.Owin;
using Owin;

[assembly: OwinStartupAttribute(typeof(Wap2013RTM.Startup))]
namespace Wap2013RTM
{
    public partial class Startup
    {
        public void Configuration(IAppBuilder app)
        {
            ConfigureAuth(app);
        }
    }
}
